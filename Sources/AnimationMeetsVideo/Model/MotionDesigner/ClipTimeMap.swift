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
    enum Kind: Equatable, Sendable {
        /// Pinned to the music: nothing but the person moves it.
        case hit
        /// Moved by the person, or by a pace marker before it.
        case marker
        /// A marker that holds the speed after it, as a percentage, to the
        /// next point.
        case pace(Double)
    }

    /// A side of a point.
    enum Side { case before, after }

    var id = UUID()
    /// The frame, in the clip's source time.
    var source: CMTime
    /// Where it plays on the timeline.
    var time: CMTime
    var kind: Kind
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

    var isHit: Bool { kind == .hit }

    var pace: Double? {
        if case .pace(let speed) = kind { return speed }
        return nil
    }

    /// The presets a point in the motion designer can take: Hold is how a
    /// pace marker steps, so it isn't offered as an ease.
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
    /// Where the clip's first frame plays while it has no points to place
    /// it; the line then runs straight at its resting speed between its
    /// edge keyframes.
    var origin: CMTime
    /// The eases of the keyframes on the clip's first and last frames: the
    /// handle leaving its first frame, and the one arriving at its last.
    /// Each has only the handle that reaches into the clip, and none until
    /// the person pulls it out. They shape the open ends while those have
    /// footage (`hasEdgeKeyframe`), which they always do on a clip with no
    /// points.
    var startEase: KeyframeEase?
    var endEase: KeyframeEase?

    static let speedRange = 1.0...10_000.0
    /// What computed times are given in, as for ramped clips.
    static let timescale: CMTimeScale = 240_000
    /// How far a new handle reaches, as Easy Ease's influence.
    static let standardInfluence = KeyframeEase.linearInfluence

    init(
        trimStart: CMTime, trimEnd: CMTime, points: [TimePoint] = [], restingSpeed: Double = 100,
        origin: CMTime = .zero, startEase: KeyframeEase? = nil, endEase: KeyframeEase? = nil
    ) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.points = points.sorted { $0.source < $1.source }
        self.restingSpeed = restingSpeed
        self.origin = origin
        self.startEase = startEase
        self.endEase = endEase
    }

    func index(of id: UUID) -> Int? { points.firstIndex(id: id) }

    // MARK: Speeds

    /// The straight-line speed from point `index` to the next, as a
    /// percentage; the open end's after the last point.
    func speed(after index: Int) -> Double {
        index + 1 < points.count ? stretchSpeed(index) : speedAfterLast
    }

    /// The open start's speed: the stretch after the first point's, or
    /// what the clip played at before a lone point or a first pace marker,
    /// whose pace is only the speed after it.
    var speedBeforeFirst: Double {
        if points.count >= 2, points[0].pace == nil { return stretchSpeed(0) }
        return restingSpeed
    }

    /// The open end's speed: a last pace marker's, else the last stretch's.
    var speedAfterLast: Double {
        if let pace = points.last?.pace { return pace }
        return points.count >= 2 ? stretchSpeed(points.count - 2) : restingSpeed
    }

    /// The straight-line speed between point `index` and the next.
    private func stretchSpeed(_ index: Int) -> Double {
        let source = CMTimeSubtract(points[index + 1].source, points[index].source).seconds
        let time = CMTimeSubtract(points[index + 1].time, points[index].time).seconds
        return time > 0 ? source / time * 100 : -1
    }

    /// The straight-line speed of the stretch on a side of point `index`.
    func straightSpeed(_ side: TimePoint.Side, of index: Int) -> Double {
        side == .before ? (index == 0 ? speedBeforeFirst : stretchSpeed(index - 1)) : speed(after: index)
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

    /// The stretches of the line, in order: the open start from the clip's
    /// first frame (where it has footage before the first point), each
    /// stretch between points, and the open end to its last frame. The open
    /// ends run at their speed, bent only by the outermost points' eases
    /// and the edge keyframes'. A clip with no points is one stretch, from
    /// its `origin` at its resting speed, between its edge keyframes.
    var stretches: [TimeStretch] {
        guard let first = points.first, let last = points.last else {
            let footage = CMTimeSubtract(trimEnd, trimStart).seconds
            guard footage > 0, restingSpeed > 0 else { return [] }
            return [TimeStretch(
                start: (origin.seconds, trimStart.seconds),
                end: (origin.seconds + footage * 100 / restingSpeed, trimEnd.seconds),
                leaving: startEase, arriving: endEase
            )]
        }
        var result: [TimeStretch] = []
        let lead = CMTimeSubtract(first.source, trimStart).seconds
        if lead > 0 {
            result.append(TimeStretch(
                start: (first.time.seconds - lead * 100 / speedBeforeFirst, trimStart.seconds),
                end: (first.time.seconds, first.source.seconds),
                leaving: edgeEase(.start), arriving: effectiveEase(.before, of: 0)
            ))
        }
        for i in points.indices.dropLast() {
            result.append(TimeStretch(
                start: (points[i].time.seconds, points[i].source.seconds),
                end: (points[i + 1].time.seconds, points[i + 1].source.seconds),
                leaving: effectiveEase(.after, of: i), arriving: effectiveEase(.before, of: i + 1)
            ))
        }
        let tail = CMTimeSubtract(trimEnd, last.source).seconds
        if tail > 0 {
            result.append(TimeStretch(
                start: (last.time.seconds, last.source.seconds),
                end: (last.time.seconds + tail * 100 / speedAfterLast, trimEnd.seconds),
                leaving: effectiveEase(.after, of: points.count - 1), arriving: edgeEase(.end)
            ))
        }
        return result
    }

    /// Where a frame plays, along the line, past the footage too.
    func time(atSource source: CMTime) -> CMTime? {
        guard let first = points.first, let last = points.last else { return nil }
        let seconds = source.seconds
        let stretches = stretches
        let result: Double
        if let stretch = stretches.first(where: { $0.start.source <= seconds && seconds <= $0.end.source }) {
            result = stretch.time(atSource: seconds)
        } else if seconds < (stretches.first?.start.source ?? first.source.seconds) {
            let from = stretches.first.map { ($0.start.time, $0.start.source) } ?? (first.time.seconds, first.source.seconds)
            result = from.0 + (seconds - from.1) * 100 / speedBeforeFirst
        } else {
            let from = stretches.last.map { ($0.end.time, $0.end.source) } ?? (last.time.seconds, last.source.seconds)
            result = from.0 + (seconds - from.1) * 100 / speedAfterLast
        }
        return CMTime(seconds: result, preferredTimescale: Self.timescale)
    }

    /// The frame playing at `time`, along the line, past the footage too.
    func source(atTime time: CMTime) -> CMTime? {
        guard let first = points.first, let last = points.last else { return nil }
        let seconds = time.seconds
        let stretches = stretches
        let result: Double
        if let stretch = stretches.first(where: { $0.start.time <= seconds && seconds <= $0.end.time }) {
            result = stretch.source(atTime: seconds)
        } else if seconds < (stretches.first?.start.time ?? first.time.seconds) {
            let from = stretches.first.map { ($0.start.time, $0.start.source) } ?? (first.time.seconds, first.source.seconds)
            result = from.1 + (seconds - from.0) * speedBeforeFirst / 100
        } else {
            let from = stretches.last.map { ($0.end.time, $0.end.source) } ?? (last.time.seconds, last.source.seconds)
            result = from.1 + (seconds - from.0) * speedAfterLast / 100
        }
        return CMTime(seconds: result, preferredTimescale: Self.timescale)
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

    // MARK: Edge keyframes

    /// Whether the clip shows a keyframe on its edge's frame: it has
    /// footage between that frame and the outermost point (a point on the
    /// very frame stands in for it), or any footage while it has no points.
    func hasEdgeKeyframe(_ edge: Edge) -> Bool {
        guard let first = points.first, let last = points.last else { return trimEnd > trimStart }
        return edge == .start ? first.source > trimStart : last.source < trimEnd
    }

    /// Whether an edge keyframe can have its handle: not the last frame
    /// after a last pace marker, which holds its pace straight to it.
    func canEase(_ edge: Edge) -> Bool {
        hasEdgeKeyframe(edge) && (edge == .start || points.last?.pace == nil)
    }

    /// The handle of an edge keyframe, nil while it has none or can't have
    /// one (`canEase`).
    func edgeEase(_ edge: Edge) -> KeyframeEase? {
        guard canEase(edge) else { return nil }
        return edge == .start ? startEase : endEase
    }

    /// The open end an edge keyframe's handle reaches into.
    func edgeStretch(_ edge: Edge) -> TimeStretch? {
        guard hasEdgeKeyframe(edge) else { return nil }
        return edge == .start ? stretches.first : stretches.last
    }

    /// The straight-line speed of the open end at an edge.
    func straightSpeed(of edge: Edge) -> Double {
        edge == .start ? speedBeforeFirst : speedAfterLast
    }

    /// The speed the line has at an edge's frame, from its handle.
    func speed(at edge: Edge) -> Double {
        straightSpeed(of: edge) * (edgeEase(edge)?.speed ?? 1)
    }

    /// Sets the handle of an edge keyframe, as dragging it does: nil takes
    /// it away, leaving the edge linear. It only ever reaches into the
    /// clip, so there is no other handle to keep in line.
    mutating func setEdgeHandle(_ edge: Edge, to ease: KeyframeEase?) {
        guard canEase(edge) else { return }
        let ease = ease.map { held($0) }
        if edge == .start { startEase = ease } else { endEase = ease }
    }

    // MARK: Editing

    /// Puts a marker on a frame where it plays now. It is eased with its
    /// handles in line at the speed the line has there, so adding it bends
    /// nothing until it is moved. Nil outside the footage or on a point's
    /// frame; with no points yet it goes where the clip plays it at `time`.
    @discardableResult
    mutating func addMarker(atSource source: CMTime, time placed: CMTime? = nil) -> UUID? {
        guard source >= trimStart, source <= trimEnd, !points.contains(where: { $0.source == source }),
              let time = time(atSource: source) ?? placed
        else { return nil }
        // The line's speed at the frame, which the new point's handles keep.
        let seconds = source.seconds
        let speed = stretches.first { $0.start.source <= seconds && seconds <= $0.end.source }.map { stretch in
            stretch.speed(atFraction: stretch.duration > 0 ? (time.seconds - stretch.start.time) / stretch.duration : 0)
        }
        let point = TimePoint(source: source, time: time, kind: .marker, smooth: true)
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
                copy.alignSmooth()
                return copy
            }
            return
        }
        let start = points[index].time.seconds
        self = Self.furthest { fraction in
            var copy = original
            copy.points[index].time = CMTime(seconds: start + (time.seconds - start) * fraction, preferredTimescale: Self.timescale)
            copy.followPaces()
            copy.alignSmooth()
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
    /// `confirmed`, then done. A pace holds its stretch straight, so the
    /// handles into it go.
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
        copy.dropUnusableEases()
        copy.alignSmooth()
        guard copy.isPlayable else { return .noRoom }
        self = copy
        return nil
    }

    /// Moves every point `delta` later on the timeline (earlier if
    /// negative), as moving the whole clip does.
    mutating func shift(by delta: CMTime) {
        for index in points.indices { points[index].time = CMTimeAdd(points[index].time, delta) }
        origin = CMTimeAdd(origin, delta)
    }

    /// Whether a side of point `index` can ease: it has footage on that
    /// side, and isn't a pace marker's stretch, which holds its pace
    /// straight to the next point.
    func canEase(_ side: TimePoint.Side, of index: Int) -> Bool {
        guard points.indices.contains(index) else { return false }
        switch side {
        case .before:
            if index == 0 { return points[0].source > trimStart }
            return points[index - 1].pace == nil
        case .after:
            if points[index].pace != nil { return false }
            return index + 1 < points.count || points[index].source < trimEnd
        }
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
        alignSmooth()
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
        dropUnusableEases()
        alignSmooth()
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

    /// Takes the eases off sides that can't ease any more, such as into a
    /// stretch a pace now holds.
    private mutating func dropUnusableEases() {
        for index in points.indices {
            if !canEase(.before, of: index) { points[index].easeIn = nil }
            if !canEase(.after, of: index) { points[index].easeOut = nil }
            if points[index].easeIn == nil || points[index].easeOut == nil { points[index].smooth = false }
        }
    }

    /// Puts the handles of each point kept in line back in line, at the
    /// speed they share between them by their reach, after the stretches
    /// around it have changed speed.
    private mutating func alignSmooth() {
        for index in points.indices where points[index].smooth {
            guard let into = points[index].easeIn, let out = points[index].easeOut,
                  canEase(.before, of: index), canEase(.after, of: index)
            else { continue }
            let left = straightSpeed(.before, of: index), right = straightSpeed(.after, of: index)
            guard left > 0, right > 0 else { continue }
            let speed = (left * into.speed * into.influence + right * out.speed * out.influence) / (into.influence + out.influence)
            setSide(.before, of: index, to: KeyframeEase(influence: into.influence, speed: speed / left))
            setSide(.after, of: index, to: KeyframeEase(influence: out.influence, speed: speed / right))
        }
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
