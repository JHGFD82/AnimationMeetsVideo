import CoreMedia
import Foundation

// A clip's time map read from its speed keyframes, and written back as
// them (see docs/motion-designer.md, "Opening on keyframed clips" and
// "Writing keyframes").

extension ClipTimeMap {
    /// The points a forward clip's speed keyframes make: a marker for each
    /// keyframe it plays, where it plays now. A keyframe after a hold is a
    /// step in speed, so a pace marker at its speed, as is the second of
    /// two keyframes a frame or less apart (the first then makes no point).
    /// A hold at the very start of the trim only sets the speed before the
    /// first point, and keyframes that only shape an eased corner (no eases
    /// of their own, beside one eased toward them) make none either: both
    /// are what writing adds.
    init(reading clip: TimelineClip, frameDuration: CMTime) {
        let keyframes = clip.time.speed.keyframes
        var points: [TimePoint] = []
        for (index, keyframe) in keyframes.enumerated() where keyframe.time >= clip.trimStart && keyframe.time <= clip.trimEnd {
            let previous = index > 0 ? keyframes[index - 1] : nil
            let next = index + 1 < keyframes.count ? keyframes[index + 1] : nil
            let isLinear = keyframe.easeIn == nil && keyframe.easeOut == nil
            var kind = TimePoint.Kind.marker
            if let previous, previous.hold {
                kind = .pace(keyframe.value)
            } else if let previous, isLinear, previous.easeOut == nil, previous.value != keyframe.value,
                      CMTimeSubtract(keyframe.time, previous.time) <= frameDuration {
                kind = .pace(keyframe.value)
                if points.last?.source == previous.time, points.last?.kind == .marker { points.removeLast() }
            } else if keyframe.hold, keyframe.time == clip.trimStart, next != nil {
                continue
            } else if isLinear, previous?.easeOut != nil || next?.easeIn != nil {
                continue
            }
            if case .pace(let speed) = kind { kind = .pace(Self.clamped(speed)) }
            points.append(TimePoint(
                source: keyframe.time, time: clip.timelineTime(forSourceTime: keyframe.time), kind: kind,
                eased: !isLinear
            ))
        }
        self.init(
            trimStart: clip.trimStart, trimEnd: clip.trimEnd, points: points,
            restingSpeed: Self.clamped(clip.speed(atSource: clip.trimStart))
        )
    }

    /// The speed keyframes that play the clip along the map, and where it
    /// then starts on the timeline; nil with no points. Between two points
    /// it plays steadily, stepping at a corner through a hold keyframe; an
    /// eased corner instead ramps over a third of the stretch either side,
    /// through the speed of the line joining the stretches, and the rest of
    /// each stretch plays at the speed that keeps its length, so every
    /// point plays where it was put. The open ends carry on at the speed the
    /// clip has at the outermost points (a last pace marker's past it).
    /// Keyframes go only where the speed changes.
    func writtenSpeed() -> (speed: AnimatedValue<Double>, start: CMTime)? {
        guard let first = points.first else { return nil }
        let count = points.count
        let source = points.map(\.source.seconds)
        let time = points.map(\.time.seconds)
        var before = Self.clamped(speedBeforeFirst)
        let after = Self.clamped(speedAfterLast)

        func left(_ i: Int) -> Double { i == 0 ? before : Self.clamped(speed(after: i - 1)) }
        func right(_ i: Int) -> Double { i == count - 1 ? after : Self.clamped(speed(after: i)) }
        func leftLength(_ i: Int) -> Double { i == 0 ? source[0] - trimStart.seconds : source[i] - source[i - 1] }
        func rightLength(_ i: Int) -> Double { i == count - 1 ? trimEnd.seconds - source[i] : source[i + 1] - source[i] }
        let eased = (0..<count).map { i in
            points[i].eased && abs(left(i) - right(i)) > 1e-9 && leftLength(i) > 0 && rightLength(i) > 0
        }
        // An eased corner passes through the speed of the line joining its
        // two stretches.
        let through = (0..<count).map { i in
            Self.clamped((leftLength(i) + rightLength(i)) / (leftLength(i) / left(i) + rightLength(i) / right(i)))
        }

        // The keyframes of the stretch after point `i`, playing `steady`
        // where it doesn't ramp; held into a sharp corner whose speed,
        // `next`, is another.
        func stretch(_ i: Int, steady: Double, next: Double? = nil) -> [Keyframe<Double>] {
            let at = { (seconds: Double) in CMTime(seconds: seconds, preferredTimescale: Self.timescale) }
            var result = [eased[i]
                ? Keyframe(time: points[i].source, value: through[i], easeIn: .easy, easeOut: .easy)
                : Keyframe(time: points[i].source, value: steady)]
            let length = rightLength(i)
            if eased[i] { result.append(Keyframe(time: at(source[i] + length / 3), value: steady)) }
            if i + 1 < count {
                if eased[i + 1] {
                    result.append(Keyframe(time: at(source[i + 1] - length / 3), value: steady))
                } else if let next, next != steady {
                    result[result.count - 1].hold = true
                }
            }
            return result
        }

        // Each stretch's steady speed: its own where nothing ramps, else
        // the one that keeps its length.
        var steady = (0..<count).map { right($0) }
        for i in 0..<(count - 1) where eased[i] || eased[i + 1] {
            let target = time[i + 1] - time[i]
            func length(_ speed: Double) -> Double {
                var keyframes = stretch(i, steady: speed)
                keyframes.append(Keyframe(time: points[i + 1].source, value: eased[i + 1] ? through[i + 1] : speed, easeIn: eased[i + 1] ? .easy : nil))
                return SpeedIntegral(AnimatedValue(speed, keyframes: keyframes)).length(from: source[i], to: source[i + 1])
            }
            var low = log(Self.speedRange.lowerBound), high = log(Self.speedRange.upperBound)
            for _ in 0..<60 {
                let middle = (low + high) / 2
                // Faster plays the stretch in less time.
                if length(exp(middle)) > target { low = middle } else { high = middle }
            }
            steady[i] = exp((low + high) / 2)
        }

        // Open ends carry on at the speed the clip has at the outermost
        // points, which a ramp nearby makes other than the stretch's
        // average, rather than stepping there.
        if count >= 2, points[count - 1].pace == nil, !eased[count - 1] { steady[count - 1] = steady[count - 2] }
        // Where each point's own keyframe starts the stretch after it.
        let starts = (0..<count).map { eased[$0] ? through[$0] : steady[$0] }
        if !eased[0] { before = starts[0] }
        var keyframes: [Keyframe<Double>] = []
        if eased[0] {
            keyframes.append(Keyframe(time: CMTime(seconds: source[0] - leftLength(0) / 3, preferredTimescale: Self.timescale), value: before))
        } else if leftLength(0) > 0, before != starts[0] {
            keyframes.append(Keyframe(time: trimStart, value: before, hold: true))
        }
        for i in 0..<count {
            keyframes += stretch(i, steady: steady[i], next: i + 1 < count ? starts[i + 1] : nil)
        }
        let curve = Self.simplified(keyframes)
        let lead = curve.isAnimated
            ? SpeedIntegral(curve).length(from: trimStart.seconds, to: first.source.seconds)
            : (first.source.seconds - trimStart.seconds) * 100 / curve.value
        return (curve, CMTime(seconds: first.time.seconds - lead, preferredTimescale: Self.timescale))
    }

    /// `keyframes` without those that change nothing, and a single value if
    /// they all hold one.
    private static func simplified(_ keyframes: [Keyframe<Double>]) -> AnimatedValue<Double> {
        var kept: [Keyframe<Double>] = []
        for (index, keyframe) in keyframes.enumerated() {
            let next = index + 1 < keyframes.count ? keyframes[index + 1] : nil
            if let previous = kept.last, previous.easeOut == nil, previous.value == keyframe.value,
               keyframe.easeIn == nil, keyframe.easeOut == nil,
               next == nil || keyframe.hold || (next?.value == keyframe.value && next?.easeIn == nil) {
                // The value is already this from the keyframe before.
                kept[kept.count - 1].hold = previous.hold || keyframe.hold
                continue
            }
            kept.append(keyframe)
        }
        if let first = kept.first, kept.allSatisfy({ $0.value == first.value }) { return AnimatedValue(first.value) }
        // The last keyframe's hold does nothing; leave it off.
        if !kept.isEmpty { kept[kept.count - 1].hold = false }
        return AnimatedValue(kept[0].value, keyframes: kept)
    }

    private static func clamped(_ speed: Double) -> Double {
        min(max(abs(speed), speedRange.lowerBound), speedRange.upperBound)
    }
}
