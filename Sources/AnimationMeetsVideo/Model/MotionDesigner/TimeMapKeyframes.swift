import CoreMedia
import Foundation

// A clip's time map read from the clip, and written back as its speed
// keyframes (see docs/motion-designer.md, "Opening on keyframed clips" and
// "Writing keyframes").

extension ClipTimeMap {
    /// Restores saved markers and locks while their speed still matches.
    /// Otherwise interior speed keys become unlocked, linear markers; the
    /// second of a pair at most a frame apart stands for their speed step.
    init(reading clip: TimelineClip, frameDuration: CMTime) {
        let start = TimePoint(source: clip.trimStart, time: clip.startOffset)
        let end = TimePoint(source: clip.trimEnd, time: clip.endOffset)
        var points: [TimePoint] = []
        var startEase: KeyframeEase?
        var endEase: KeyframeEase?
        if let design = clip.time.design, design.speed == clip.time.speed {
            points = design.points.filter { $0.source >= clip.trimStart && $0.source <= clip.trimEnd }.map {
                TimePoint(source: $0.source, time: clip.timelineTime(forSourceTime: $0.source),
                          locked: $0.locked, easeIn: $0.easeIn, easeOut: $0.easeOut, smooth: $0.smooth)
            }
            startEase = design.startEase
            endEase = design.endEase
        } else {
            let keys = clip.time.speed.keyframes
            for (i, key) in keys.enumerated() where key.time > clip.trimStart && key.time < clip.trimEnd {
                if i + 1 < keys.count, keys[i + 1].time - key.time <= frameDuration,
                   keys[i + 1].value != key.value { continue }
                points.append(TimePoint(source: key.time, time: clip.timelineTime(forSourceTime: key.time)))
            }
        }
        if !points.contains(where: { $0.source == start.source }) { points.append(start) }
        if !points.contains(where: { $0.source == end.source }) { points.append(end) }
        self.init(trimStart: clip.trimStart, trimEnd: clip.trimEnd, points: points,
                  origin: clip.startOffset, startEase: startEase, endEase: endEase)
    }

    /// Writes each neighbouring pair as speed keyframes, straight or in
    /// held steps following its curve. Every stretch keeps its length.
    /// The run writes only edited clips, preserving untouched keyframes.
    func writtenSpeed() -> (speed: AnimatedValue<Double>, start: CMTime)? {
        let stretches = stretches
        var keyframes: [Keyframe<Double>] = []
        // Rounded to the nearest tick: `CMTime(seconds:)` cuts a time a hair
        // short of a tick back to the one before.
        let at = { (seconds: Double) in CMTime(value: Int64((seconds * Double(Self.timescale)).rounded()), timescale: Self.timescale) }
        // Each stretch starts on a point's frame, or the clip's first, kept
        // as it is rather than put on the keyframes' timescale.
        let frames = [trimStart] + points.map(\.source)
        for stretch in stretches {
            for step in Self.steps(of: stretch) {
                let time = step.source == stretch.start.source ? frames.first { $0.seconds == step.source } ?? at(step.source) : at(step.source)
                keyframes.append(Keyframe(time: time, value: step.speed, hold: true))
            }
        }
        if keyframes.isEmpty {
            // A lone point at the clip's only frame: it plays at its speed.
            keyframes.append(Keyframe(time: points.first?.source ?? trimStart, value: Self.clamped(speed(after: 0))))
        }
        let curve = Self.simplified(keyframes)
        let start = stretches.first?.start.time ?? points.first?.time.seconds ?? 0
        return (curve, points.first?.time ?? at(start))
    }

    /// Where a stretch's speed steps, and the speed after each: one step
    /// for a straight stretch, else one for each part of its time, held to
    /// what Time allows and solved so they keep the stretch's length.
    static func steps(of stretch: TimeStretch) -> [(source: Double, speed: Double)] {
        guard stretch.footage > 0, stretch.duration > 0 else { return [] }
        if stretch.isStraight { return [(stretch.start.source, clamped(stretch.speed))] }
        // About a step every 1/24 s, the curve's own shape in each.
        let count = Int((stretch.duration * 24).rounded()).clamped(between: 8, and: 64)
        // On the times keyframes are written at, so each step plays the
        // footage its speed is worked out from.
        let grid = Double(timescale)
        var sources = (0...count).map { ((stretch.start.source + stretch.footage * stretch.progress(Double($0) / Double(count))) * grid).rounded() / grid }
        sources[0] = stretch.start.source
        sources[count] = stretch.end.source
        let span = stretch.duration / Double(count)
        var parts: [(source: Double, footage: Double, speed: Double)] = []
        for index in 0..<count {
            let footage = sources[index + 1] - sources[index]
            guard footage > 0 else { continue }
            parts.append((sources[index], footage, footage / span * 100))
        }
        guard !parts.isEmpty else { return [] }
        // Held parts take the time Time's limits give them; the rest share
        // what's left, scaled together so the stretch keeps its length.
        var speeds = parts.map { clamped($0.speed) }
        for _ in 0..<8 {
            let held = parts.indices.filter { speeds[$0] <= speedRange.lowerBound || speeds[$0] >= speedRange.upperBound }
            let free = parts.indices.filter { !held.contains($0) }
            let heldTime = held.reduce(0.0) { $0 + parts[$1].footage * 100 / speeds[$1] }
            let freeTime = free.reduce(0.0) { $0 + parts[$1].footage * 100 / speeds[$1] }
            let left = stretch.duration - heldTime
            guard !free.isEmpty, left > 0, freeTime > 0, abs(freeTime - left) > 1e-12 else { break }
            let factor = freeTime / left
            for index in free { speeds[index] = clamped(speeds[index] * factor) }
        }
        return merged(parts.indices.map { (parts[$0].source, parts[$0].footage, speeds[$0]) }, from: stretch.start.time)
    }

    /// How far a merged step may play a frame from where the curve plays
    /// it, in seconds: about a quarter of a frame.
    static let stepTolerance = 1.0 / 96

    /// `steps` with neighbours joined wherever playing them as one step,
    /// their footage over their time, keeps every frame within
    /// `stepTolerance` of where the steps play it. Each joined step still
    /// starts and ends where they did, so the stretch keeps its length.
    private static func merged(_ steps: [(source: Double, footage: Double, speed: Double)], from start: Double) -> [(source: Double, speed: Double)] {
        // Where each step starts playing, and where the last ends.
        var times = [start]
        for step in steps { times.append(times[times.count - 1] + step.footage * 100 / step.speed) }
        var result: [(source: Double, speed: Double)] = []
        var first = 0
        while first < steps.count {
            var last = first
            while last + 1 < steps.count {
                let end = last + 1
                let footage = steps[first...end].reduce(0.0) { $0 + $1.footage }
                let speed = footage / (times[end + 1] - times[first]) * 100
                // Every boundary inside plays near where the steps play it.
                let fits = (first + 1...end).allSatisfy { inside in
                    let played = times[first] + (steps[inside].source - steps[first].source) * 100 / speed
                    return abs(played - times[inside]) <= stepTolerance
                }
                guard fits, speedRange.contains(speed) else { break }
                last = end
            }
            let footage = steps[first...last].reduce(0.0) { $0 + $1.footage }
            result.append((steps[first].source, footage / (times[last + 1] - times[first]) * 100))
            first = last + 1
        }
        return result
    }

    /// `keyframes` without those that only repeat the speed before them, and
    /// a single value if they all hold one.
    private static func simplified(_ keyframes: [Keyframe<Double>]) -> AnimatedValue<Double> {
        var kept: [Keyframe<Double>] = []
        for keyframe in keyframes {
            if let previous = kept.last, previous.value == keyframe.value { continue }
            kept.append(keyframe)
        }
        if let first = kept.first, kept.allSatisfy({ $0.value == first.value }) { return AnimatedValue(first.value) }
        // The last keyframe's hold does nothing; leave it off.
        kept[kept.count - 1].hold = false
        return AnimatedValue(kept[0].value, keyframes: kept)
    }

    fileprivate static func clamped(_ speed: Double) -> Double {
        abs(speed).clamped(between: speedRange.lowerBound, and: speedRange.upperBound)
    }
}
