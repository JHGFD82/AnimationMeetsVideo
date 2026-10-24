import CoreMedia
import Foundation

// The motion designer's working state for one clip: the frames the person
// has pinned or dragged, and where on the timeline each plays (see
// docs/motion-designer.md). Between two points the clip plays steadily, so
// the map is a line through them; the speed keyframes it is written as come
// from `TimeMapKeyframes`.

/// A frame of a clip placed on the timeline in the motion designer.
struct TimePoint: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Pinned to the music: nothing but the person moves it.
        case hit
        /// Moved by the person, or by a pace marker before it.
        case marker
        /// A marker that sets the speed after it, as a percentage.
        case pace(Double)
    }

    var id = UUID()
    /// The frame, in the clip's source time.
    var source: CMTime
    /// Where it plays on the timeline.
    var time: CMTime
    var kind: Kind
    /// How the speed ramps through it, when it does instead of stepping.
    var ease: TimeEase?

    /// Whether the speed ramps through it instead of stepping.
    var eased: Bool { ease != nil }

    var isHit: Bool { kind == .hit }

    var pace: Double? {
        if case .pace(let speed) = kind { return speed }
        return nil
    }
}

/// How far an eased point's ramp reaches into the stretch on either side,
/// as a share of that stretch: the ramp's handles on the graph. The rest of
/// each stretch plays steadily at the speed that keeps its length, so
/// longer ramps never move a point.
struct TimeEase: Equatable {
    var before: Double
    var after: Double

    /// A share of a stretch a ramp may reach; two ramps meeting in one
    /// stretch share `limit` of it.
    static let reach = 0.05...0.9
    static let limit = 0.9

    init(before: Double = 1.0 / 3, after: Double = 1.0 / 3) {
        self.before = before.clamped(between: Self.reach.lowerBound, and: Self.reach.upperBound)
        self.after = after.clamped(between: Self.reach.lowerBound, and: Self.reach.upperBound)
    }
}

/// One clip's points, in source order, and the footage it plays.
struct ClipTimeMap: Equatable {
    /// Why an edit didn't happen until the person agrees to what it costs.
    enum Conflict: Equatable {
        /// A pace marker would have to move this hit, which becomes a marker.
        case hitWouldMove(UUID)
        /// A hit would end this pace marker, which becomes a marker.
        case paceWouldEnd(UUID)
        /// No speed the clip can play at fits the edit.
        case noRoom
    }

    var trimStart: CMTime
    var trimEnd: CMTime
    /// In source order, each later on the timeline than the one before.
    private(set) var points: [TimePoint]
    /// The speed of the open ends while fewer than two points set one.
    var restingSpeed: Double

    static let speedRange = 1.0...10_000.0
    /// What computed times are given in, as for ramped clips.
    static let timescale: CMTimeScale = 240_000

    init(trimStart: CMTime, trimEnd: CMTime, points: [TimePoint] = [], restingSpeed: Double = 100) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.points = points.sorted { $0.source < $1.source }
        self.restingSpeed = restingSpeed
    }

    func index(of id: UUID) -> Int? { points.firstIndex(id: id) }

    // MARK: Speeds

    /// The speed from point `index` to the next, as a percentage; the open
    /// end's after the last point.
    func speed(after index: Int) -> Double {
        index + 1 < points.count ? stretchSpeed(index) : speedAfterLast
    }

    /// The open start's speed: the stretch after the first point's, or
    /// what a lone point plays at.
    var speedBeforeFirst: Double {
        if points.count >= 2 { return stretchSpeed(0) }
        return points.first?.pace ?? restingSpeed
    }

    /// The open end's speed: a last pace marker's, else the last stretch's.
    var speedAfterLast: Double {
        if let pace = points.last?.pace { return pace }
        return points.count >= 2 ? stretchSpeed(points.count - 2) : restingSpeed
    }

    /// The speed between point `index` and the next.
    private func stretchSpeed(_ index: Int) -> Double {
        let source = CMTimeSubtract(points[index + 1].source, points[index].source).seconds
        let time = CMTimeSubtract(points[index + 1].time, points[index].time).seconds
        return time > 0 ? source / time * 100 : -1
    }

    /// Where a frame plays, along the line through the points.
    func time(atSource source: CMTime) -> CMTime? {
        guard let first = points.first, let last = points.last else { return nil }
        func along(_ from: TimePoint, speed: Double) -> CMTime {
            let seconds = from.time.seconds + CMTimeSubtract(source, from.source).seconds * 100 / speed
            return CMTime(seconds: seconds, preferredTimescale: Self.timescale)
        }
        if source <= first.source { return along(first, speed: speedBeforeFirst) }
        if source >= last.source { return along(last, speed: speedAfterLast) }
        let next = points.firstIndex { $0.source > source }! - 1
        return along(points[next], speed: speed(after: next))
    }

    /// The frame playing at `time`, along the line through the points, past
    /// the footage too.
    func source(atTime time: CMTime) -> CMTime? {
        guard let first = points.first, let last = points.last else { return nil }
        func along(_ from: TimePoint, speed: Double) -> CMTime {
            let seconds = from.source.seconds + CMTimeSubtract(time, from.time).seconds * speed / 100
            return CMTime(seconds: seconds, preferredTimescale: Self.timescale)
        }
        if time <= first.time { return along(first, speed: speedBeforeFirst) }
        if time >= last.time { return along(last, speed: speedAfterLast) }
        let index = points.firstIndex { $0.time > time }! - 1
        return along(points[index], speed: speed(after: index))
    }

    /// Where the clip starts and ends on the timeline, along the line.
    var span: (start: CMTime, end: CMTime)? {
        guard let start = time(atSource: trimStart), let end = time(atSource: trimEnd) else { return nil }
        return (start, end)
    }

    /// Whether every stretch plays forwards at a speed the clip can play.
    var isPlayable: Bool {
        guard points.indices.dropLast().allSatisfy({ Self.speedRange.contains(speed(after: $0)) }) else { return false }
        return Self.speedRange.contains(speedBeforeFirst) && Self.speedRange.contains(speedAfterLast)
    }

    // MARK: Editing

    /// Puts a marker on a frame where it plays now, which changes nothing
    /// until it is moved. Nil outside the footage or on a point's frame;
    /// with no points yet it goes where the clip plays it at `time`.
    @discardableResult
    mutating func addMarker(atSource source: CMTime, time placed: CMTime? = nil) -> UUID? {
        guard source >= trimStart, source <= trimEnd, !points.contains(where: { $0.source == source }),
              let time = time(atSource: source) ?? placed
        else { return nil }
        let point = TimePoint(source: source, time: time, kind: .marker)
        points.append(point)
        points.sort { $0.source < $1.source }
        return point.id
    }

    /// Moves a point along the timeline, as far toward `time` as the clip
    /// can play. A point after a pace marker sets that marker's pace
    /// instead; one with a pace marker before it in a run moves the run.
    mutating func move(_ id: UUID, to time: CMTime) {
        guard let index = index(of: id) else { return }
        let original = self
        if index > 0, let old = points[index - 1].pace {
            let source = CMTimeSubtract(points[index].source, points[index - 1].source).seconds
            let span = CMTimeSubtract(time, points[index - 1].time).seconds
            let wanted = span > 0 ? (source / span * 100).clamped(between: Self.speedRange.lowerBound, and: Self.speedRange.upperBound) : Self.speedRange.upperBound
            self = Self.furthest { fraction in
                var copy = original
                copy.points[index - 1].kind = .pace(old + (wanted - old) * fraction)
                copy.followPaces()
                return copy
            }
            return
        }
        let start = points[index].time.seconds
        self = Self.furthest { fraction in
            var copy = original
            copy.points[index].time = CMTime(seconds: start + (time.seconds - start) * fraction, preferredTimescale: Self.timescale)
            copy.followPaces()
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

    /// Makes a point a hit, a marker or a pace marker. A pace marker before
    /// a hit would move it, and a hit right after a pace marker would end
    /// that pace: each is refused with what it would cost until
    /// `confirmed`, then done.
    @discardableResult
    mutating func setKind(_ kind: TimePoint.Kind, of id: UUID, confirmed: Bool = false) -> Conflict? {
        guard let index = index(of: id) else { return nil }
        var copy = self
        switch kind {
        case .pace(let speed):
            if index + 1 < points.count, points[index + 1].isHit {
                guard confirmed else { return .hitWouldMove(points[index + 1].id) }
                copy.points[index + 1].kind = .marker
            }
            copy.points[index].kind = .pace(speed.clamped(between: Self.speedRange.lowerBound, and: Self.speedRange.upperBound))
        case .hit:
            if index > 0, points[index - 1].pace != nil {
                guard confirmed else { return .paceWouldEnd(points[index - 1].id) }
                copy.points[index - 1].kind = .marker
            }
            copy.points[index].kind = .hit
        case .marker:
            copy.points[index].kind = .marker
        }
        copy.followPaces()
        guard copy.isPlayable else { return .noRoom }
        self = copy
        return nil
    }

    /// Moves every point `delta` later on the timeline (earlier if
    /// negative), as moving the whole clip does.
    mutating func shift(by delta: CMTime) {
        for index in points.indices { points[index].time = CMTimeAdd(points[index].time, delta) }
    }

    mutating func setEased(_ eased: Bool, of id: UUID) {
        guard let index = index(of: id) else { return }
        guard eased else {
            points[index].ease = nil
            return
        }
        if points[index].ease == nil { setEase(TimeEase(), of: id) }
    }

    /// Shapes an eased point's ramps, each kept within the room the ramp of
    /// the point beyond leaves in their stretch.
    mutating func setEase(_ ease: TimeEase, of id: UUID) {
        guard let index = index(of: id) else { return }
        var ease = ease
        if index > 0, let other = points[index - 1].ease {
            ease.before = min(ease.before, TimeEase.limit - other.after)
        }
        if index + 1 < points.count, let other = points[index + 1].ease {
            ease.after = min(ease.after, TimeEase.limit - other.before)
        }
        points[index].ease = TimeEase(before: ease.before, after: ease.after)
    }

    /// Takes a point away. A pace marker left right before a hit becomes a
    /// marker, since it can't move the hit.
    mutating func remove(_ id: UUID) {
        guard let index = index(of: id) else { return }
        points.remove(at: index)
        if index > 0, index < points.count, points[index - 1].pace != nil, points[index].isHit {
            points[index - 1].kind = .marker
        }
        followPaces()
    }

    /// Puts each point after a pace marker where that pace takes it, in
    /// order, so a run of pace markers carries on.
    private mutating func followPaces() {
        for index in points.indices.dropLast() {
            guard let pace = points[index].pace, !points[index + 1].isHit else { continue }
            let source = CMTimeSubtract(points[index + 1].source, points[index].source).seconds
            points[index + 1].time = CMTime(
                seconds: points[index].time.seconds + source * 100 / pace, preferredTimescale: Self.timescale
            )
        }
    }
}
