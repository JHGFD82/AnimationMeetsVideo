import CoreGraphics
import CoreMedia
import Foundation

// The motion designer's working state for one clip: the frames the person
// has pinned or dropped, where on the timeline each plays, and how the line
// bends between them (see docs/motion-designer.md). The line is a value
// graph of the clip's source time over timeline time, each stretch between
// two points shaped by the eases either side as a keyframe's segment is;
// the speed keyframes it is written as come from `TimeMapKeyframes`.

/// A frame of a clip placed on the timeline in the motion designer.
struct TimePoint: Identifiable, Equatable {
    /// A side of a point.
    enum Side { case before, after }

    var id = UUID()
    /// The frame, in the clip's source time.
    var source: CMTime
    /// Where it plays on the timeline.
    var time: CMTime
    var locked = false
    /// How the line arrives at it and leaves it, as a keyframe's Ease In and
    /// Ease Out: a handle reaching `influence` of the stretch on that side
    /// along the timeline, at `speed` times the stretch's straight-line
    /// speed, so 0 stops at the point and 1 carries on as the straight line
    /// would. Nil on a side whose handle sits on the straight line, a third
    /// of the way along, as a keyframe's linear side does.
    var easeIn: KeyframeEase?
    var easeOut: KeyframeEase?
    /// Whether its handles stay in line, so the speed carries through it
    /// without stepping. Points dropped on the line start so; moving one
    /// handle alone breaks it.
    var smooth = false

    func ease(_ side: Side) -> KeyframeEase? { side == .before ? easeIn : easeOut }

    var eased: Bool { easeIn != nil || easeOut != nil }

    /// Its ease, named as keyframes' are: Linear when neither side eases.
    var easePreset: KeyframeEase.Preset {
        switch (easeIn, easeOut) {
        case (.some, .some): .easyEase
        case (.some, nil): .easeIn
        case (nil, .some): .easeOut
        case (nil, nil): .linear
        }
    }

    /// Easing presets available to every marker.
    static let presets: [KeyframeEase.Preset] = [.linear, .easeIn, .easeOut, .easyEase]
}

/// One stretch of a clip's line: from a point, or the clip's first frame,
/// to the next point, or its last frame. Timeline seconds across, source
/// seconds up; between its ends it follows the cubic a keyframe segment
/// would, its handles the eases leaving its start and arriving at its end.
struct TimeStretch: Equatable {
    var start: (time: Double, source: Double)
    var end: (time: Double, source: Double)
    var leaving: KeyframeEase?
    var arriving: KeyframeEase?

    static func == (a: TimeStretch, b: TimeStretch) -> Bool {
        a.start == b.start && a.end == b.end && a.leaving == b.leaving && a.arriving == b.arriving
    }

    var duration: Double { end.time - start.time }
    var footage: Double { end.source - start.source }

    /// Its straight-line speed, as a percentage.
    var speed: Double { duration > 0 ? footage / duration * 100 : -1 }

    var isStraight: Bool {
        // A side on the straight line, a third of the way along, is linear.
        func straight(_ ease: KeyframeEase?) -> Bool {
            guard let ease else { return true }
            return abs(ease.speed - 1) < 1e-12 && abs(ease.influence - KeyframeEase.linearInfluence) < 1e-12
        }
        return straight(leaving) && straight(arriving)
    }

    /// The frame playing `time` seconds into the timeline.
    func source(atTime time: Double) -> Double {
        guard duration > 0 else { return end.source }
        let fraction = ((time - start.time) / duration).clamped(between: 0, and: 1)
        return start.source + footage * progress(fraction)
    }

    /// Where the frame at `source` seconds plays.
    func time(atSource source: Double) -> Double {
        guard footage > 0 else { return start.time }
        let wanted = ((source - start.source) / footage).clamped(between: 0, and: 1)
        if isStraight { return start.time + duration * wanted }
        // Progress only grows across the stretch (handles are held to
        // the stretch's unit square), so it can be searched.
        var low = 0.0, high = 1.0
        for _ in 0..<52 {
            let middle = (low + high) / 2
            if progress(middle) < wanted { low = middle } else { high = middle }
        }
        return start.time + duration * (low + high) / 2
    }

    /// How far through its footage the stretch has got when `fraction` of
    /// its time has passed.
    func progress(_ fraction: Double) -> Double {
        isStraight ? fraction : KeyframeEase.progress(fraction, leaving: leaving, arriving: arriving)
    }

    /// The speed, as a percentage, `fraction` of the way through its time,
    /// from the curve's slope.
    func speed(atFraction fraction: Double) -> Double {
        let step = 1e-4
        let a = max(0, fraction - step), b = min(1, fraction + step)
        return (progress(b) - progress(a)) / (b - a) * speed
    }
}

/// One clip's points, in source order, and the footage it plays.
struct ClipTimeMap: Equatable {
    /// Which edge of a clip.
    enum Edge: Hashable { case start, end }

    /// In source order, including the first and last frame markers.
    private(set) var points: [TimePoint]
    var trimStart: CMTime { points[0].source }
    var trimEnd: CMTime { points[points.count - 1].source }

    static let speedRange = 1.0...10_000.0
    /// What computed times are given in, as for ramped clips.
    static let timescale: CMTimeScale = 240_000
    /// How far a new handle reaches, as Easy Ease's influence.
    static let standardInfluence = KeyframeEase.linearInfluence

    init(
        trimStart: CMTime, trimEnd: CMTime, points: [TimePoint] = [], restingSpeed: Double = 100,
        origin: CMTime = .zero, startEase: KeyframeEase? = nil, endEase: KeyframeEase? = nil
    ) {
        let interior = points.filter { $0.source > trimStart && $0.source < trimEnd }
        let first = points.first { $0.source == trimStart }
        let last = points.first { $0.source == trimEnd }
        // Callers reading a clip pass its actual edge times. For a new map,
        // its supplied speed places the edges independently of its markers.
        self.points = [TimePoint(source: trimStart, time: first?.time ?? origin,
                                 locked: first?.locked ?? false, easeOut: startEase ?? first?.easeOut)]
            + interior.sorted { $0.source < $1.source }
            + [TimePoint(source: trimEnd, time: last?.time ?? CMTimeAdd(origin,
                CMTime(seconds: (trimEnd - trimStart).seconds * 100 / restingSpeed, preferredTimescale: Self.timescale)),
                         locked: last?.locked ?? false, easeIn: endEase ?? last?.easeIn)]
    }

    func index(of id: UUID) -> Int? { points.firstIndex(id: id) }

    // MARK: Speeds

    func speed(after index: Int) -> Double {
        stretchSpeed(min(index, points.count - 2))
    }

    /// The straight-line speed between point `index` and the next.
    private func stretchSpeed(_ index: Int) -> Double {
        let source = CMTimeSubtract(points[index + 1].source, points[index].source).seconds
        let time = CMTimeSubtract(points[index + 1].time, points[index].time).seconds
        return time > 0 ? source / time * 100 : -1
    }

    /// The straight-line speed of the stretch on a side of point `index`.
    func straightSpeed(_ side: TimePoint.Side, of index: Int) -> Double {
        side == .before ? stretchSpeed(max(0, index - 1)) : speed(after: index)
    }

    /// The speed the line has at point `index` on a side, from its handle.
    func speed(_ side: TimePoint.Side, at index: Int) -> Double {
        let straight = straightSpeed(side, of: index)
        guard let ease = effectiveEase(side, of: index) else { return straight }
        return straight * ease.speed
    }

    // MARK: Stretches

    /// The ease that shapes the line on a side of point `index`: none where
    /// the side can't ease (`canEase`).
    private func effectiveEase(_ side: TimePoint.Side, of index: Int) -> KeyframeEase? {
        canEase(side, of: index) ? points[index].ease(side) : nil
    }

    var stretches: [TimeStretch] {
        zip(points, points.dropFirst()).map { first, last in
            TimeStretch(start: (first.time.seconds, first.source.seconds),
                        end: (last.time.seconds, last.source.seconds),
                        leaving: first.easeOut, arriving: last.easeIn)
        }
    }

    /// Where a frame plays, along the line, past the footage too.
    func time(atSource source: CMTime) -> CMTime? {
        if let point = points.first(where: { $0.source == source }) { return point.time }
        guard let first = points.first, let last = points.last else { return nil }
        // A straight stretch can be interpolated as exact rational times.
        // This matters at 1% and 10000%, where rounding a newly inserted
        // marker by a tick would put one adjacent stretch past the limit.
        for (a, b) in zip(points, points.dropFirst()) where a.source < source && source < b.source {
            let index = self.index(of: a.id)!
            if stretches[index].isStraight {
                let offset = source - a.source
                let footage = CMTimeConvertScale(b.source - a.source, timescale: offset.timescale, method: .default)
                if abs(offset.value) <= Int32.max, abs(footage.value) <= Int32.max, footage.value > 0 {
                    return a.time + CMTimeMultiplyByRatio(b.time - a.time, multiplier: Int32(offset.value), divisor: Int32(footage.value))
                }
            }
        }
        let seconds = source.seconds
        let stretches = stretches
        let result: Double
        if let stretch = stretches.first(where: { $0.start.source <= seconds && seconds <= $0.end.source }) {
            result = stretch.time(atSource: seconds)
        } else if seconds < (stretches.first?.start.source ?? first.source.seconds) {
            let from = stretches.first.map { ($0.start.time, $0.start.source) } ?? (first.time.seconds, first.source.seconds)
            result = from.0 + (seconds - from.1) * 100 / speed(after: 0)
        } else {
            let from = stretches.last.map { ($0.end.time, $0.end.source) } ?? (last.time.seconds, last.source.seconds)
            result = from.0 + (seconds - from.1) * 100 / speed(after: points.count - 2)
        }
        return CMTime(seconds: result, preferredTimescale: Self.timescale)
    }

    /// The frame playing at `time`, along the line, past the footage too.
    func source(atTime time: CMTime) -> CMTime? {
        if let point = points.first(where: { $0.time == time }) { return point.source }
        guard let first = points.first, let last = points.last else { return nil }
        let seconds = time.seconds
        let stretches = stretches
        let result: Double
        if let stretch = stretches.first(where: { $0.start.time <= seconds && seconds <= $0.end.time }) {
            result = stretch.source(atTime: seconds)
        } else if seconds < (stretches.first?.start.time ?? first.time.seconds) {
            let from = stretches.first.map { ($0.start.time, $0.start.source) } ?? (first.time.seconds, first.source.seconds)
            result = from.1 + (seconds - from.0) * speed(after: 0) / 100
        } else {
            let from = stretches.last.map { ($0.end.time, $0.end.source) } ?? (last.time.seconds, last.source.seconds)
            result = from.1 + (seconds - from.0) * speed(after: points.count - 2) / 100
        }
        return CMTime(seconds: result, preferredTimescale: Self.timescale)
    }

    /// Where the clip starts and ends on the timeline, along the line.
    var span: (start: CMTime, end: CMTime)? {
        guard let start = time(atSource: trimStart), let end = time(atSource: trimEnd) else { return nil }
        return (start, end)
    }

    var isPlayable: Bool {
        stretches.allSatisfy {
            // Subtracting nearby Double times can put an exact boundary
            // a few ulps outside the range. This is below a time tick.
            $0.speed >= Self.speedRange.lowerBound - 1e-10
                && $0.speed <= Self.speedRange.upperBound + 1e-8 && $0.footage > 0
        }
    }

    func isEdge(_ id: UUID) -> Bool { points.first?.id == id || points.last?.id == id }

    /// Trim footage along the existing line, preserving the edge handle.
    mutating func trim(_ edge: Edge, to time: CMTime, within footage: CMTimeRange, frame: CMTime) {
        let i = edge == .start ? 0 : points.count - 1
        guard !points[i].locked, let source = source(atTime: time) else { return }
        let neighbour = points[edge == .start ? 1 : points.count - 2]
        let bounded = edge == .start
            ? CMTimeMinimum(CMTimeMaximum(source, footage.start), neighbour.source - frame)
            : CMTimeMaximum(CMTimeMinimum(source, footage.end), neighbour.source + frame)
        guard bounded >= footage.start, bounded <= footage.end,
              let placed = self.time(atSource: bounded) else { return }
        points[i].source = bounded
        points[i].time = placed
    }

    // MARK: Editing

    /// Puts a marker on a frame where it plays now. It is eased with its
    /// handles in line at the speed the line has there, so adding it bends
    /// nothing until it is moved. Nil outside the footage or on a point's
    /// frame; with no points yet it goes where the clip plays it at `time`.
    @discardableResult
    mutating func addMarker(atSource source: CMTime, time placed: CMTime? = nil) -> UUID? {
        guard source > trimStart, source < trimEnd, !points.contains(where: { $0.source == source }),
              let time = time(atSource: source) ?? placed
        else { return nil }
        // The line's speed at the frame, which the new point's handles keep.
        let seconds = source.seconds
        let speed = stretches.first { $0.start.source <= seconds && seconds <= $0.end.source }.map { stretch in
            stretch.speed(atFraction: stretch.duration > 0 ? (time.seconds - stretch.start.time) / stretch.duration : 0)
        }
        let point = TimePoint(source: source, time: time, smooth: true)
        points.append(point)
        points.sort { $0.source < $1.source }
        guard let index = index(of: point.id) else { return point.id }
        for side in [TimePoint.Side.before, .after] where canEase(side, of: index) {
            let straight = straightSpeed(side, of: index)
            let ratio = speed.map { straight > 0 ? $0 / straight : 1 } ?? 1
            setSide(side, of: index, to: KeyframeEase(influence: Self.standardInfluence, speed: ratio))
        }
        return point.id
    }

    /// Moves an unlocked marker along time, stopping at the speed limits.
    mutating func move(_ id: UUID, to time: CMTime) {
        guard let index = index(of: id), !points[index].locked, points[index].time != time else { return }
        let original = self
        let start = points[index].time.seconds
        self = Self.furthest { fraction in
            var copy = original
            copy.points[index].time = CMTime(seconds: start + (time.seconds - start) * fraction, preferredTimescale: Self.timescale)
            copy.alignSmooth(at: index)
            copy.alignNeighbours(around: index)
            return copy
        }
    }

    /// `edit(1)` if it is playable, else the edit nearest it that is, from
    /// `edit(0)`, the map as it was, which is.
    private static func furthest(_ edit: (Double) -> ClipTimeMap) -> ClipTimeMap {
        let whole = edit(1)
        if whole.isPlayable { return whole }
        var low = 0.0, high = 1.0
        for _ in 0..<50 {
            let middle = (low + high) / 2
            if edit(middle).isPlayable { low = middle } else { high = middle }
        }
        return edit(low)
    }

    mutating func setLocked(_ locked: Bool, of id: UUID) {
        guard let i = index(of: id) else { return }
        points[i].locked = locked
    }

    /// Moves every point `delta` later on the timeline (earlier if
    /// negative), as moving the whole clip does.
    mutating func shift(by delta: CMTime) {
        for index in points.indices { points[index].time = CMTimeAdd(points[index].time, delta) }
    }

    /// Whether there is a neighbouring stretch on this side.
    func canEase(_ side: TimePoint.Side, of index: Int) -> Bool {
        guard points.indices.contains(index) else { return false }
        return side == .before ? index > 0 : index + 1 < points.count
    }

    /// Whether either side of a point can ease.
    func canEase(_ id: UUID) -> Bool {
        guard let index = index(of: id) else { return false }
        return canEase(.before, of: index) || canEase(.after, of: index)
    }

    /// Sets a point's ease by its preset, as a keyframe's menu does: Linear
    /// (or Hold) puts both handles back on the straight line, Ease In and
    /// Ease Out slow the footage into the point or out of it, and Easy Ease
    /// both, each eased side stopping at the point (`KeyframeEase.easy`).
    /// Only sides that can ease take one.
    mutating func setEase(_ preset: KeyframeEase.Preset, of id: UUID) {
        guard let index = index(of: id) else { return }
        let wantsIn = preset == .easeIn || preset == .easyEase
        let wantsOut = preset == .easeOut || preset == .easyEase
        points[index].easeIn = wantsIn && canEase(.before, of: index) ? .easy : nil
        points[index].easeOut = wantsOut && canEase(.after, of: index) ? .easy : nil
        // Both stopping, the handles lie flat, in line.
        points[index].smooth = points[index].easeIn != nil && points[index].easeOut != nil
    }

    /// Sets the handle on a side of a point, as dragging it does: nil puts
    /// that side back on the straight line. Unless `alone`, the handle on
    /// the other side swings to stay in line with it, so the speed carries
    /// through the point, as a keyframe's handles do; alone, they part, and
    /// the speed steps there.
    mutating func setHandle(_ side: TimePoint.Side, of id: UUID, to ease: KeyframeEase?, alone: Bool = false) {
        guard let index = index(of: id), canEase(side, of: index) else { return }
        guard let ease else {
            setSide(side, of: index, to: nil)
            points[index].smooth = false
            return
        }
        setSide(side, of: index, to: ease)
        let other: TimePoint.Side = side == .before ? .after : .before
        if alone {
            points[index].smooth = false
        } else if let theirs = points[index].ease(other), canEase(other, of: index) {
            let speed = straightSpeed(side, of: index) * held(ease).speed
            let straight = straightSpeed(other, of: index)
            setSide(other, of: index, to: KeyframeEase(influence: theirs.influence, speed: straight > 0 ? speed / straight : theirs.speed))
            points[index].smooth = true
        }
    }

    /// Keeps a point's handles in line, bringing them into line at the
    /// speed they share, or lets them part, as Option-dragging one does.
    /// Only a point eased on both sides has two handles to keep in line.
    mutating func setSmooth(_ smooth: Bool, of id: UUID) {
        guard let index = index(of: id) else { return }
        points[index].smooth = smooth && points[index].easeIn != nil && points[index].easeOut != nil
        alignSmooth(at: index)
    }

    mutating func remove(_ id: UUID) {
        guard let index = index(of: id), !isEdge(id), !points[index].locked else { return }
        points.remove(at: index)
    }

    // MARK: Keeping it together

    private mutating func setSide(_ side: TimePoint.Side, of index: Int, to ease: KeyframeEase?) {
        let ease = ease.map { held($0) }
        if side == .before { points[index].easeIn = ease } else { points[index].easeOut = ease }
    }

    /// An ease held to what the line can do: its handle inside the
    /// stretch's unit square, so the footage never runs backwards.
    private func held(_ ease: KeyframeEase) -> KeyframeEase {
        KeyframeEase(influence: ease.influence, speed: ease.speed.clamped(between: 0, and: 1 / ease.influence))
    }

    /// Keep smooth neighbours aligned by changing only their handle into
    /// the moved marker. Their handle into the untouched stretch stays
    /// exactly as it was, so that stretch never changes shape.
    private mutating func alignNeighbours(around index: Int) {
        for neighbour in [index - 1, index + 1] where neighbour > 0 && neighbour + 1 < points.count {
            guard points[neighbour].smooth,
                  let into = points[neighbour].easeIn, let out = points[neighbour].easeOut else { continue }
            if neighbour < index {
                let speed = straightSpeed(.before, of: neighbour) * into.speed
                setSide(.after, of: neighbour, to: KeyframeEase(influence: out.influence,
                    speed: speed / straightSpeed(.after, of: neighbour)))
            } else {
                let speed = straightSpeed(.after, of: neighbour) * out.speed
                setSide(.before, of: neighbour, to: KeyframeEase(influence: into.influence,
                    speed: speed / straightSpeed(.before, of: neighbour)))
            }
        }
    }

    /// Puts the handles of each point kept in line back in line, at the
    /// speed they share between them by their reach, after the stretches
    /// around it have changed speed.
    private mutating func alignSmooth(at index: Int) {
        if points[index].smooth {
            guard let into = points[index].easeIn, let out = points[index].easeOut,
                  canEase(.before, of: index), canEase(.after, of: index)
            else { return }
            let left = straightSpeed(.before, of: index), right = straightSpeed(.after, of: index)
            guard left > 0, right > 0 else { return }
            let speed = (left * into.speed * into.influence + right * out.speed * out.influence) / (into.influence + out.influence)
            setSide(.before, of: index, to: KeyframeEase(influence: into.influence, speed: speed / left))
            setSide(.after, of: index, to: KeyframeEase(influence: out.influence, speed: speed / right))
        }
    }

}
