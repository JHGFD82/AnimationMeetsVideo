import CoreMedia
import Foundation

/// A tone curve: what each tone becomes, from black (0) to reference white
/// (1), through points joined smoothly (see docs/effects-correction.md,
/// "Curves"). A curve control holds one, saved as its points' numbers in
/// turn, `[x0, y0, x1, y1, …]`, so it keyframes as any control's numbers
/// do, point by point.
///
/// Between its points it is a monotone cubic (PCHIP, Fritsch and
/// Butland's): it passes through every point and never overshoots
/// between two, so a curve that rises everywhere keeps the tones in order
/// and never clips by itself. Before its first point it holds that
/// point's tone, after its last that one's; past reference white (HDR
/// highlights) a curve ending at x = 1 carries on along the slope of its
/// last stretch, as Levels does.
struct ToneCurve: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        var x: Double
        var y: Double
    }

    /// Sorted by `x`, at least `minimumGap` apart, all within 0...1; at
    /// least two.
    private(set) var points: [Point]

    /// The closest two points may be across.
    static let minimumGap = 0.01

    /// Every tone as it is: black to black, white to white.
    static let identity = ToneCurve(checked: [Point(x: 0, y: 0), Point(x: 1, y: 1)])

    /// The numbers a new curve control holds.
    static let identityValues = identity.values

    private init(checked points: [Point]) {
        self.points = points
    }

    /// The curve through `points`, put in order and within 0...1, those
    /// closer than `minimumGap` to the one before left out; the identity
    /// if fewer than two are left.
    init(points: [Point]) {
        var kept: [Point] = []
        for point in points.filter({ $0.x.isFinite && $0.y.isFinite }).sorted(by: { $0.x < $1.x }) {
            let point = Point(x: point.x.clamped(between: 0, and: 1), y: point.y.clamped(between: 0, and: 1))
            if let last = kept.last, point.x - last.x < Self.minimumGap { continue }
            kept.append(point)
        }
        self.points = kept.count >= 2 ? kept : Self.identity.points
    }

    /// The curve a control's numbers hold, read leniently: pairs in turn,
    /// an odd number left over dropped.
    init(values: [Double]) {
        self.init(points: stride(from: 0, to: values.count - 1, by: 2).map { Point(x: values[$0], y: values[$0 + 1]) })
    }

    /// Its points' numbers in turn, as a control holds them.
    var values: [Double] { points.flatMap { [$0.x, $0.y] } }

    /// Whether it changes no tone between black and white.
    var isIdentity: Bool {
        guard let first = points.first, let last = points.last, first.x == 0, last.x == 1 else { return false }
        return points.allSatisfy { abs($0.x - $0.y) < 1e-9 }
    }

    // MARK: Reading

    /// The slope at each point, Fritsch and Butland's: zero at a peak or a
    /// dip, else a weighted harmonic mean of the slopes beside it, which
    /// keeps every piece within the tones of its two ends.
    private var tangents: [Double] {
        let n = points.count
        let h = (0..<(n - 1)).map { points[$0 + 1].x - points[$0].x }
        let d = (0..<(n - 1)).map { (points[$0 + 1].y - points[$0].y) / h[$0] }
        guard n > 2 else { return [d[0], d[0]] }
        var m = [Double](repeating: 0, count: n)
        for k in 1..<(n - 1) where d[k - 1] * d[k] > 0 {
            let w1 = 2 * h[k] + h[k - 1], w2 = h[k] + 2 * h[k - 1]
            m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k])
        }
        // The ends, from the two pieces beside them, held to the same
        // shape: never against the first piece's slope, nor steeper than
        // three times it when the curve turns just after.
        func end(_ h0: Double, _ h1: Double, _ d0: Double, _ d1: Double) -> Double {
            let slope = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
            if slope * d0 <= 0 { return 0 }
            if d0 * d1 <= 0, abs(slope) > abs(3 * d0) { return 3 * d0 }
            return slope
        }
        m[0] = end(h[0], h[1], d[0], d[1])
        m[n - 1] = end(h[n - 2], h[n - 3], d[n - 2], d[n - 3])
        return m
    }

    /// The tone `x` becomes.
    func value(at x: Double) -> Double {
        sample([x])[0]
    }

    /// The tones each of `xs` becomes, the tangents worked out once.
    func sample(_ xs: [Double]) -> [Double] {
        let m = tangents
        return xs.map { x in
            guard let first = points.first, let last = points.last else { return x }
            if x <= first.x { return first.y }
            if x >= last.x { return last.y + max(x - 1, 0) * slopeAtWhite }
            let k = max(points.lastIndex { $0.x <= x } ?? 0, 0)
            let a = points[k], b = points[k + 1]
            let h = b.x - a.x
            let t = (x - a.x) / h
            let t2 = t * t, t3 = t2 * t
            return (2 * t3 - 3 * t2 + 1) * a.y + (t3 - 2 * t2 + t) * h * m[k] + (-2 * t3 + 3 * t2) * b.y + (t3 - t2) * h * m[k + 1]
        }
    }

    /// The slope tones past white carry on along: its last stretch's, from
    /// the point before white to white, rather than the curve's own slope
    /// there, which a curve easing into white makes 0 and would clip every
    /// HDR highlight to the same tone. 0 when its last point is before
    /// white, where it is flat.
    var slopeAtWhite: Double {
        let n = points.count
        guard n >= 2, points[n - 1].x == 1 else { return 0 }
        return (points[n - 1].y - points[n - 2].y) / (points[n - 1].x - points[n - 2].x)
    }

    /// `count` evenly spaced tones from black to white as the curve maps
    /// them: the table a kernel reads it from (`ToneCurveTable`).
    func table(count: Int) -> [Double] {
        sample((0..<count).map { Double($0) / Double(max(count - 1, 1)) })
    }

    // MARK: Editing

    /// How far point `index` may go across: past neither neighbor, keeping
    /// `minimumGap` from each.
    func xRange(ofPoint index: Int) -> ClosedRange<Double> {
        let low = index > 0 ? points[index - 1].x + Self.minimumGap : 0
        let high = index < points.count - 1 ? points[index + 1].x - Self.minimumGap : 1
        return low...max(low, high)
    }

    /// Point `index` moved to (`x`, `y`), held between its neighbors and
    /// within 0...1.
    func moving(_ index: Int, toX x: Double, y: Double) -> ToneCurve {
        guard points.indices.contains(index), x.isFinite, y.isFinite else { return self }
        var copy = self
        let range = xRange(ofPoint: index)
        copy.points[index] = Point(x: x.clamped(between: range.lowerBound, and: range.upperBound), y: y.clamped(between: 0, and: 1))
        return copy
    }

    /// Where a point at `x` would go among the points, or nil when it is
    /// within `minimumGap` of one.
    func insertionIndex(atX x: Double) -> Int? {
        guard x.isFinite, (0...1).contains(x), !points.contains(where: { abs($0.x - x) < Self.minimumGap }) else { return nil }
        return points.firstIndex { $0.x > x } ?? points.count
    }

    /// The curve with a point at `x` on it, so its shape barely changes;
    /// itself when one is within `minimumGap` of `x`.
    func inserting(atX x: Double) -> ToneCurve {
        guard let index = insertionIndex(atX: x) else { return self }
        var copy = self
        copy.points.insert(Point(x: x, y: value(at: x).clamped(between: 0, and: 1)), at: index)
        return copy
    }

    /// The curve without point `index`; itself when only two are left.
    func removing(_ index: Int) -> ToneCurve {
        guard points.count > 2, points.indices.contains(index) else { return self }
        var copy = self
        copy.points.remove(at: index)
        return copy
    }

    /// The middle of the widest gap between points, where a new one fits
    /// best when there is no place to click (VoiceOver, the keyboard).
    var widestGapMiddle: Double {
        let gaps = zip(points, points.dropFirst()).map { ($0.x + $1.x) / 2 }
        let widths = zip(points, points.dropFirst()).map { $1.x - $0.x }
        return widths.indices.max { widths[$0] < widths[$1] }.map { gaps[$0] } ?? 0.5
    }
}

/// The color a curve control's line is drawn in on its effect's graph: the
/// channel it works on, or white for all of them.
enum CurveTint: String, CaseIterable, Sendable {
    case white, red, green, blue
}

// MARK: - Curve controls

extension EffectControl {
    /// The curve a curve control holds at source time `time`.
    func curve(at time: CMTime) -> ToneCurve {
        ToneCurve(values: values(at: time))
    }

    /// Sets the curve at `time` (a keyframe when animated). It must have as
    /// many points as the control's keyframes, which `insertCurvePoint`
    /// and `removeCurvePoint` keep the same.
    mutating func setCurve(_ curve: ToneCurve, at time: CMTime) {
        guard kind.isCurve else { return }
        number.set(ComponentValue(values: curve.values), at: time)
    }

    /// Adds a point at tone `x` to the curve and to every keyframe's, each
    /// on its own curve there, so every keyframe keeps its shape and they
    /// still blend point by point. Returns the new point's index, or nil
    /// when the curve at `time` has a point within `ToneCurve.minimumGap`.
    @discardableResult
    mutating func insertCurvePoint(atX x: Double, at time: CMTime) -> Int? {
        guard kind.isCurve, let index = curve(at: time).insertionIndex(atX: x) else { return nil }
        number.mapValues { value in
            // Each keyframe's own pairs, as saved, so none is dropped.
            var values = value.values
            let count = values.count / 2
            let at = min(index, count)
            // Another keyframe's points may sit elsewhere: keep this one's
            // order, putting the new point between its neighbors there.
            let low = at > 0 ? values[at * 2 - 2] : 0
            let high = at < count ? values[at * 2] : 1
            let placed = x > low && x < high ? x : (low + high) / 2
            values.insert(contentsOf: [placed, ToneCurve(values: value.values).value(at: placed)], at: at * 2)
            return ComponentValue(values: values)
        }
        return index
    }

    /// Removes point `index` from the curve and every keyframe's, leaving
    /// at least two.
    mutating func removeCurvePoint(_ index: Int) {
        guard kind.isCurve, ToneCurve(values: number.value.values).points.count > 2 else { return }
        number.mapValues { value in
            var values = value.values
            guard values.count > 4, values.indices.contains(index * 2 + 1) else { return value }
            values.removeSubrange((index * 2)...(index * 2 + 1))
            return ComponentValue(values: values)
        }
    }
}
