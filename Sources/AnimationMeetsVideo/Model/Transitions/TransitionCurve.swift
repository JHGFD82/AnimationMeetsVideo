import CoreGraphics
import Foundation

/// How a transition progresses over its length: a chain of cubic bezier
/// segments from (0, 0) to (1, 1), where x is the fraction of the
/// transition's length that has passed and y how far the transition has
/// got. The first and last points are fixed; points in between can be
/// added, moved and removed.
///
/// Each point has a handle on either side, as an offset from the point in
/// the same units, or none for a sharp corner. A segment whose two inner
/// handles are both missing is a straight line.
struct TransitionCurve: Equatable, Sendable {
    struct Point: Equatable {
        var time: Double
        var value: Double
        var inHandle: CGVector?
        var outHandle: CGVector?

        var location: CGPoint { CGPoint(x: time, y: value) }
    }

    enum HandleSide {
        case incoming, outgoing
    }

    /// The ready-made shapes, named as in After Effects: easing *out* leaves
    /// the start slowly, easing *in* arrives at the end slowly.
    enum Preset: CaseIterable, Identifiable {
        case linear, easeIn, easeOut, easyEase

        var id: Self { self }

        var name: String {
            switch self {
            case .linear: "Linear"
            case .easeIn: "Ease In"
            case .easeOut: "Ease Out"
            case .easyEase: "Easy Ease"
            }
        }

        var detail: String {
            switch self {
            case .linear: "Steady from start to end"
            case .easeIn: "Slows into the end"
            case .easeOut: "Starts slowly"
            case .easyEase: "Starts and ends slowly"
            }
        }
    }

    /// Always at least the two end points, in order of time.
    private(set) var points: [Point]

    /// How far an eased handle reaches, as After Effects' default 33%
    /// influence.
    static let influence = 1.0 / 3

    static let linear = TransitionCurve(preset: .linear)

    init(preset: Preset) {
        let ease = CGVector(dx: Self.influence, dy: 0)
        var start = Point(time: 0, value: 0)
        var end = Point(time: 1, value: 1)
        if preset == .easeOut || preset == .easyEase { start.outHandle = ease }
        if preset == .easeIn || preset == .easyEase { end.inHandle = CGVector(dx: -ease.dx, dy: 0) }
        points = [start, end]
    }

    /// A curve from saved points, or nil if they don't run from (0, 0) to
    /// (1, 1) in increasing time. Handles are brought back within range.
    init?(points: [Point]) {
        guard points.count >= 2,
              points.first?.location == .zero, points.last?.location == CGPoint(x: 1, y: 1),
              zip(points, points.dropFirst()).allSatisfy({ $0.time < $1.time })
        else {
            return nil
        }
        self.points = points
        self.points[0].inHandle = nil
        self.points[points.count - 1].outHandle = nil
        for index in self.points.indices { clampHandles(of: index) }
    }

    /// The preset this curve is exactly, if any.
    var preset: Preset? {
        Preset.allCases.first { TransitionCurve(preset: $0) == self }
    }

    var segmentCount: Int { points.count - 1 }

    /// The four bezier control points of segment `index`, between point
    /// `index` and the next. A missing handle sits on its point.
    func controlPoints(ofSegment index: Int) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let a = points[index], b = points[index + 1]
        let p1 = a.outHandle.map { a.location + $0 } ?? a.location
        let p2 = b.inHandle.map { b.location + $0 } ?? b.location
        return (a.location, p1, p2, b.location)
    }

    func segment(containingTime time: Double) -> Int {
        let clamped = min(max(time, 0), 1)
        return (points.lastIndex { $0.time <= clamped } ?? 0).clamped(to: 0...(segmentCount - 1))
    }

    /// How far the transition has got after `time` (0...1) of its length.
    /// Handles may push this a little outside 0...1.
    func value(at time: Double) -> Double {
        let t = min(max(time, 0), 1)
        let index = segment(containingTime: t)
        let controls = controlPoints(ofSegment: index)
        // Exact at the points themselves, which the halving only nears.
        if t <= Double(controls.0.x) { return Double(controls.0.y) }
        if t >= Double(controls.3.x) { return Double(controls.3.y) }
        if points[index].outHandle == nil, points[index + 1].inHandle == nil {
            let (start, end) = (controls.0, controls.3)
            return Double(start.y) + (t - Double(start.x)) / Double(end.x - start.x) * Double(end.y - start.y)
        }
        return Double(Self.point(on: controls, at: Self.parameter(forTime: t, on: controls)).y)
    }

    // MARK: Editing

    /// Adds a point on the curve at `time` without changing its shape: the
    /// segment it falls in is split in two. Returns the new point's index,
    /// or nil when `time` is on or next to an existing point.
    @discardableResult
    mutating func insertPoint(atTime time: Double) -> Int? {
        guard time > 0, time < 1 else { return nil }
        let index = segment(containingTime: time)
        guard time - points[index].time > 0.01, points[index + 1].time - time > 0.01 else { return nil }
        let (p0, p1, p2, p3) = controlPoints(ofSegment: index)
        let s = CGFloat(Self.parameter(forTime: time, on: (p0, p1, p2, p3)))
        let p01 = p0.lerp(p1, s), p12 = p1.lerp(p2, s), p23 = p2.lerp(p3, s)
        let p012 = p01.lerp(p12, s), p123 = p12.lerp(p23, s)
        let split = p012.lerp(p123, s)

        let straight = points[index].outHandle == nil && points[index + 1].inHandle == nil
        var point = Point(time: Double(split.x), value: Double(split.y))
        if !straight {
            points[index].outHandle = (p01 - p0).nonZero
            points[index + 1].inHandle = (p23 - p3).nonZero
            point.inHandle = (p012 - split).nonZero
            point.outHandle = (p123 - split).nonZero
        }
        points.insert(point, at: index + 1)
        return index + 1
    }

    /// Moves a point between its neighbors. The end points stay put.
    mutating func movePoint(_ index: Int, to location: CGPoint) {
        guard index > 0, index < points.count - 1 else { return }
        let gap = 0.01
        points[index].time = min(max(Double(location.x), points[index - 1].time + gap), points[index + 1].time - gap)
        points[index].value = min(max(Double(location.y), 0), 1)
        clampHandles(of: index - 1)
        clampHandles(of: index)
        clampHandles(of: index + 1)
    }

    /// Sets one handle of a point. It can't point backward in time or reach
    /// past the neighboring point, so the curve never turns back on itself.
    mutating func setHandle(_ side: HandleSide, of index: Int, to offset: CGVector) {
        guard points.indices.contains(index) else { return }
        switch side {
        case .incoming:
            guard index > 0 else { return }
            points[index].inHandle = offset
        case .outgoing:
            guard index < points.count - 1 else { return }
            points[index].outHandle = offset
        }
        clampHandles(of: index)
    }

    /// Option-click on a point: a curved point becomes a sharp corner, and
    /// a corner gets smooth handles that follow its neighbors (flat at the
    /// two ends, like Easy Ease).
    mutating func toggleCorner(_ index: Int) {
        guard points.indices.contains(index) else { return }
        if points[index].inHandle != nil || points[index].outHandle != nil {
            points[index].inHandle = nil
            points[index].outHandle = nil
            return
        }
        let point = points[index]
        let previous = index > 0 ? points[index - 1] : nil
        let next = index < points.count - 1 ? points[index + 1] : nil
        var slope = 0.0
        if let previous, let next {
            slope = (next.value - previous.value) / (next.time - previous.time)
        }
        if let previous {
            let reach = (point.time - previous.time) * Self.influence
            points[index].inHandle = CGVector(dx: -reach, dy: -reach * slope)
        }
        if let next {
            let reach = (next.time - point.time) * Self.influence
            points[index].outHandle = CGVector(dx: reach, dy: reach * slope)
        }
        clampHandles(of: index)
    }

    /// Option-click on the line: the segment becomes straight.
    mutating func straightenSegment(_ index: Int) {
        guard index >= 0, index < segmentCount else { return }
        points[index].outHandle = nil
        points[index + 1].inHandle = nil
    }

    /// Removes a point between the ends.
    mutating func removePoint(_ index: Int) {
        guard index > 0, index < points.count - 1 else { return }
        points.remove(at: index)
    }

    private mutating func clampHandles(of index: Int) {
        guard points.indices.contains(index) else { return }
        if index > 0, var handle = points[index].inHandle {
            let reach = points[index].time - points[index - 1].time
            handle.dx = min(max(handle.dx, -reach), 0)
            points[index].inHandle = handle.nonZero
        }
        if index < points.count - 1, var handle = points[index].outHandle {
            let reach = points[index + 1].time - points[index].time
            handle.dx = max(min(handle.dx, reach), 0)
            points[index].outHandle = handle.nonZero
        }
    }

    // MARK: Bezier math

    static func point(on controls: (CGPoint, CGPoint, CGPoint, CGPoint), at s: Double) -> CGPoint {
        let s = CGFloat(s), r = 1 - s
        let (p0, p1, p2, p3) = controls
        let a = r * r * r, b = 3 * r * r * s, c = 3 * r * s * s, d = s * s * s
        return CGPoint(
            x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
            y: a * p0.y + b * p1.y + c * p2.y + d * p3.y
        )
    }

    /// The bezier parameter where the segment reaches `time`. Handles never
    /// point backward, so x only grows along a segment and halving finds it.
    static func parameter(forTime time: Double, on controls: (CGPoint, CGPoint, CGPoint, CGPoint)) -> Double {
        // 52 halvings reach Double's precision; 40 left 1e-12 in the
        // parameter, which a speed ramp's integral would carry.
        var low = 0.0, high = 1.0
        for _ in 0..<52 {
            let mid = (low + high) / 2
            if Double(point(on: controls, at: mid).x) < time { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}

private extension CGPoint {
    static func + (point: CGPoint, offset: CGVector) -> CGPoint {
        CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
    }

    static func - (a: CGPoint, b: CGPoint) -> CGVector {
        CGVector(dx: a.x - b.x, dy: a.y - b.y)
    }

    func lerp(_ other: CGPoint, _ s: CGFloat) -> CGPoint {
        CGPoint(x: x + (other.x - x) * s, y: y + (other.y - y) * s)
    }
}

private extension CGVector {
    /// Nil for a handle with no length, which is the same as no handle.
    var nonZero: CGVector? {
        abs(dx) < 1e-9 && abs(dy) < 1e-9 ? nil : self
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
