import CoreMedia
import Foundation

// Gradients (see docs/gradients.md): a shape's Fill or Stroke painted with
// a gradient instead of one color. The color control keeps its place and
// its keyframes: a `PaintStyle` on it says it holds a gradient, and its
// numbers are then the gradient's points and stops (`PaintGradient`) rather
// than red, green, blue and alpha, so every point and stop is keyframed as
// the color was. Stops are matched by their order, and every keyframe has
// as many: adding or taking one out does it at every keyframe.

/// The shape of a gradient.
enum GradientKind: String, CaseIterable, Identifiable, Sendable {
    /// From a start point to an end point.
    case linear
    /// From a center out to the edge point's distance, from a focal point
    /// that may lie off the center, stretched across by `aspect`.
    case radial
    /// Around a center, from the direction of the edge point.
    case angular

    var id: Self { self }

    var name: String {
        switch self {
        case .linear: "Linear"
        case .radial: "Radial"
        case .angular: "Angular"
        }
    }

    var systemImage: String {
        switch self {
        case .linear: "square.fill.and.line.vertical.and.square"
        case .radial: "circle.dotted.circle"
        case .angular: "dial.low"
        }
    }
}

/// What a gradient does past its ends.
enum GradientRepeat: String, CaseIterable, Identifiable, Sendable {
    /// Holds its end colors.
    case hold
    /// Starts again from its first stop.
    case repeats
    /// Goes back and forth.
    case reflect

    var id: Self { self }

    var name: String {
        switch self {
        case .hold: "Hold"
        case .repeats: "Repeat"
        case .reflect: "Reflect"
        }
    }
}

/// How a gradient blends between its stops.
enum GradientBlend: String, CaseIterable, Identifiable, Sendable {
    /// In the timeline's own values, as colors are drawn.
    case values
    /// In OKLab, whose middles don't go gray or muddy between saturated
    /// colors.
    case perceptual

    var id: Self { self }

    var name: String {
        switch self {
        case .values: "Timeline Values"
        case .perceptual: "Perceptual"
        }
    }
}

/// What a gradient's points are measured against.
enum GradientSpace: String, CaseIterable, Identifiable, Sendable {
    /// The item's bounds: it moves, scales and turns with the shape, and
    /// fits another shape it is copied to.
    case item
    /// The frame: still while the item moves through it.
    case frame

    var id: Self { self }

    var name: String {
        switch self {
        case .item: "Relative to Item"
        case .frame: "Relative to Frame"
        }
    }
}

/// How a color control paints when it holds a gradient: its kind and how
/// it is laid out, which aren't keyframed. Nil on a control (the default)
/// paints its one color.
struct PaintStyle: Equatable, Sendable {
    var kind = GradientKind.linear
    var repeats = GradientRepeat.hold
    var blend = GradientBlend.values
    var space = GradientSpace.item
}

/// A gradient's points and stops, as a color control holding one keeps
/// them in its numbers: the start (or center), the end (or edge), the
/// focal point's offset from the center as a share of the radius, and the
/// aspect, then six numbers a stop. Points are shares of the item's
/// bounds or the frame (`GradientSpace`), 0 the left or top edge, 1 the
/// right or bottom.
struct PaintGradient: Equatable, Sendable {
    struct Stop: Equatable, Sendable {
        /// Red, green, blue and alpha, 0...1.
        var color: [Double]
        /// Where it is along the gradient, 0...1.
        var location: Double
        /// Where, between this stop and the next, the two colors are half
        /// and half: a share of the way (0.5 is the middle).
        var midpoint = 0.5
    }

    var start: CGPoint
    var end: CGPoint
    /// Radial only: where the gradient spreads from, as an offset from the
    /// center in radii.
    var focal = CGPoint.zero
    /// Radial only: how far across it reaches, as a share of how far along.
    var aspect = 1.0
    var stops: [Stop]

    static let geometryCount = 7
    static let numbersPerStop = 6

    init(start: CGPoint, end: CGPoint, focal: CGPoint = .zero, aspect: Double = 1, stops: [Stop]) {
        self.start = start
        self.end = end
        self.focal = focal
        self.aspect = aspect
        self.stops = stops
    }

    /// The gradient a color control's numbers hold; nil when they don't
    /// hold one (a color's four, or a gradient of fewer than two stops).
    init?(values: [Double]) {
        let stopNumbers = values.count - Self.geometryCount
        guard stopNumbers >= 2 * Self.numbersPerStop, stopNumbers % Self.numbersPerStop == 0 else { return nil }
        start = CGPoint(x: values[0], y: values[1])
        end = CGPoint(x: values[2], y: values[3])
        focal = CGPoint(x: values[4], y: values[5])
        aspect = values[6]
        stops = stride(from: Self.geometryCount, to: values.count, by: Self.numbersPerStop).map { i in
            Stop(
                color: Array(values[i..<(i + 4)]).map { $0.clamped(between: 0, and: 1) },
                location: values[i + 4].clamped(between: 0, and: 1),
                midpoint: values[i + 5].clamped(between: 0.01, and: 0.99)
            )
        }
    }

    /// Its numbers, as a color control holding it keeps them.
    var values: [Double] {
        var values = [Double(start.x), Double(start.y), Double(end.x), Double(end.y), Double(focal.x), Double(focal.y), aspect]
        for stop in stops { values += stop.color + [stop.location, stop.midpoint] }
        return values
    }

    /// A new gradient of `kind` from `first` to `last`, across the item
    /// from left to right, or out from its middle.
    static func made(_ kind: GradientKind, from first: [Double], to last: [Double]) -> PaintGradient {
        let stops = [Stop(color: first, location: 0), Stop(color: last, location: 1)]
        switch kind {
        case .linear: return PaintGradient(start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5), stops: stops)
        case .radial, .angular: return PaintGradient(start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 1, y: 0.5), stops: stops)
        }
    }

    // MARK: Colors

    /// The color at `position` along the gradient (0 its start, 1 its end),
    /// past its ends as `repeats` says, blended as `blend` says.
    func color(at position: Double, repeats: GradientRepeat = .hold, blend: GradientBlend = .values) -> [Double] {
        Self.color(at: Self.wrapped(position, repeats), of: sortedStops, blend: blend)
    }

    /// The stops in the order they lie, those at one place in their own
    /// order.
    var sortedStops: [Stop] {
        stops.enumerated().sorted { ($0.element.location, $0.offset) < ($1.element.location, $1.offset) }.map(\.element)
    }

    /// The color at `t` (0...1) of stops in the order they lie.
    private static func color(at t: Double, of sorted: [Stop], blend: GradientBlend) -> [Double] {
        guard let first = sorted.first, let last = sorted.last else { return [0, 0, 0, 0] }
        if t <= first.location { return first.color }
        if t >= last.location { return last.color }
        // The pair it falls between.
        var i = 0
        while i + 1 < sorted.count, sorted[i + 1].location < t { i += 1 }
        let a = sorted[i], b = sorted[i + 1]
        let span = b.location - a.location
        // Two stops at one place make a hard edge.
        guard span > 1e-9 else { return b.color }
        let u = leaned((t - a.location) / span, midpoint: a.midpoint)
        switch blend {
        case .values:
            return zip(a.color, b.color).map { $0 + ($1 - $0) * u }
        case .perceptual:
            let from = OKLab(rgb: a.color), to = OKLab(rgb: b.color)
            let mixed = OKLab(l: from.l + (to.l - from.l) * u, a: from.a + (to.a - from.a) * u, b: from.b + (to.b - from.b) * u)
            let alpha = a.color[3] + (b.color[3] - a.color[3]) * u
            return mixed.rgb + [alpha]
        }
    }

    /// `count` colors evenly along one length of it, for drawing.
    func samples(_ count: Int, blend: GradientBlend) -> [[Double]] {
        let n = max(count, 2)
        let sorted = sortedStops
        return (0..<n).map { Self.color(at: Double($0) / Double(n - 1), of: sorted, blend: blend) }
    }

    /// `position` brought back into 0...1 as `repeats` says.
    static func wrapped(_ position: Double, _ repeats: GradientRepeat) -> Double {
        switch repeats {
        case .hold: return position.clamped(between: 0, and: 1)
        case .repeats:
            let f = position - floor(position)
            // The end of each length is the end color, not the start's.
            return f == 0 && position > 0 ? 1 : f
        case .reflect:
            let cycle = position.truncatingRemainder(dividingBy: 2)
            let f = abs(cycle < 0 ? cycle + 2 : cycle)
            return f > 1 ? 2 - f : f
        }
    }

    /// How far from one stop's color to the next's at `progress` of the way
    /// between them, leaning toward the side the midpoint is moved to: at
    /// the midpoint it is half way. A midpoint past the middle is the
    /// mirror of one before it, so a reversed gradient (`reversed`) draws
    /// the same colors the other way: a curve of one power for both
    /// leaned more steeply one way than the other.
    static func leaned(_ progress: Double, midpoint: Double) -> Double {
        let u = progress.clamped(between: 0, and: 1)
        let m = midpoint.clamped(between: 0.01, and: 0.99)
        guard abs(m - 0.5) > 1e-9 else { return u }
        guard m < 0.5 else { return 1 - leaned(1 - u, midpoint: 1 - m) }
        return pow(u, log(0.5) / log(m))
    }

    // MARK: Editing

    /// Where a stop added at `location` goes among the stops: after those
    /// before it.
    func insertionIndex(at location: Double) -> Int {
        let spot = location.clamped(between: 0, and: 1)
        return stops.firstIndex { $0.location > spot } ?? stops.count
    }

    /// With a stop at `location` put in at `index`, of the color the
    /// gradient has there.
    func inserting(at index: Int, location: Double, blend: GradientBlend) -> PaintGradient {
        var gradient = self
        let spot = location.clamped(between: 0, and: 1)
        gradient.stops.insert(Stop(color: color(at: spot, blend: blend), location: spot), at: min(max(index, 0), stops.count))
        return gradient
    }

    /// The stops in the opposite order, each where its mirror was, and each
    /// midpoint mirrored with the pair it lies between.
    var reversed: PaintGradient {
        var gradient = self
        let flipped = Array(stops.reversed())
        gradient.stops = flipped.indices.map { k in
            var mirrored = flipped[k]
            mirrored.location = 1 - flipped[k].location
            mirrored.midpoint = k + 1 < flipped.count ? 1 - flipped[k + 1].midpoint : 0.5
            return mirrored
        }
        return gradient
    }

    /// The stops spaced evenly, in the order they lie.
    var distributed: PaintGradient {
        var gradient = self
        let order = stops.indices.sorted { (stops[$0].location, $0) < (stops[$1].location, $1) }
        let last = Double(max(stops.count - 1, 1))
        for (n, index) in order.enumerated() { gradient.stops[index].location = Double(n) / last }
        return gradient
    }
}

// MARK: - OKLab

/// A color in OKLab (Björn Ottosson's), for blending that keeps saturated
/// colors' middles bright.
struct OKLab: Equatable {
    var l: Double
    var a: Double
    var b: Double

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// From red, green and blue taken as sRGB-encoded, 0...1.
    init(rgb: [Double]) {
        let r = Self.linear(rgb[0]), g = Self.linear(rgb[1]), bl = Self.linear(rgb[2])
        let lms = [
            0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl,
            0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl,
            0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl,
        ].map { cbrt($0) }
        l = 0.2104542553 * lms[0] + 0.7936177850 * lms[1] - 0.0040720468 * lms[2]
        a = 1.9779984951 * lms[0] - 2.4285922050 * lms[1] + 0.4505937099 * lms[2]
        b = 0.0259040371 * lms[0] + 0.7827717662 * lms[1] - 0.8086757660 * lms[2]
    }

    /// Back to sRGB-encoded red, green and blue, 0...1.
    var rgb: [Double] {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let (lc, mc, sc) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
        let linear = [
            4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
            -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
            -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc,
        ]
        return linear.map { Self.encoded($0).clamped(between: 0, and: 1) }
    }

    private static func linear(_ value: Double) -> Double {
        let v = value.clamped(between: 0, and: 1)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ value: Double) -> Double {
        value <= 0.0031308 ? 12.92 * value : 1.055 * pow(max(value, 0), 1 / 2.4) - 0.055
    }
}

// MARK: - On a color control

extension ControlKind {
    /// Whether a color of this kind can hold a gradient: a shape's Fill and
    /// Stroke, and the Stroke effect's.
    var takesGradient: Bool { self == .fill || self == .stroke }
}

extension EffectControl {
    /// The gradient it paints at `time`, if it holds one.
    func gradient(at time: CMTime) -> PaintGradient? {
        guard paint != nil else { return nil }
        return PaintGradient(values: values(at: time))
    }

    /// Its one color at `time`: a color's, or a gradient's first stop's.
    func solidColor(at time: CMTime) -> [Double] {
        if let gradient = gradient(at: time) { return gradient.stops.first?.color ?? [0, 0, 0, 1] }
        let values = values(at: time)
        return values.count == 4 ? values : kind.defaultValues
    }

    /// Paints with a gradient of `kind`, or one color with nil, at every
    /// keyframe: a color becomes a gradient from it to black, and a
    /// gradient a color of its first stop. A gradient of another kind keeps
    /// its stops and points.
    mutating func setPaint(_ kind: GradientKind?) {
        guard kind != paint?.kind || (kind == nil) != (paint == nil) else { return }
        func converted(_ value: ComponentValue) -> ComponentValue {
            if let kind {
                if paint != nil, PaintGradient(values: value.values) != nil { return value }
                let color = value.values.count == 4 ? value.values : self.kind.defaultValues
                return ComponentValue(values: PaintGradient.made(kind, from: color, to: [0, 0, 0, 1]).values)
            }
            guard let gradient = PaintGradient(values: value.values) else { return value }
            return ComponentValue(values: gradient.stops.first?.color ?? self.kind.defaultValues)
        }
        number = AnimatedValue(converted(number.value), keyframes: number.keyframes.map { $0.with(value: converted($0.value)) })
        if let kind {
            var style = paint ?? PaintStyle()
            style.kind = kind
            paint = style
        } else {
            paint = nil
        }
    }

    /// Changes the gradient at `time`, at a keyframe there when keyframed.
    mutating func editGradient(at time: CMTime, _ change: (inout PaintGradient) -> Void) {
        guard var gradient = gradient(at: time) else { return }
        change(&gradient)
        number.set(ComponentValue(values: gradient.values), at: time)
    }

    /// Changes the gradient's stops in the same way at every keyframe, so
    /// every keyframe keeps as many: adding a stop, taking one out,
    /// reversing them.
    mutating func editGradientEverywhere(_ change: (PaintGradient) -> PaintGradient) {
        guard paint != nil else { return }
        func changed(_ value: ComponentValue) -> ComponentValue {
            guard let gradient = PaintGradient(values: value.values) else { return value }
            return ComponentValue(values: change(gradient).values)
        }
        number = AnimatedValue(changed(number.value), keyframes: number.keyframes.map { $0.with(value: changed($0.value)) })
    }

    /// Adds a stop at `location` at every keyframe, of the color each has
    /// there, at the place among the stops it takes in the gradient at
    /// `time`, so it is the same stop at every keyframe. Returns its index.
    @discardableResult
    mutating func addGradientStop(at location: Double, time: CMTime) -> Int? {
        guard let blend = paint?.blend, let shown = gradient(at: time) else { return nil }
        let index = shown.insertionIndex(at: location)
        editGradientEverywhere { $0.inserting(at: index, location: location, blend: blend) }
        return index
    }

    /// Takes stop `index` out at every keyframe; a gradient keeps at least
    /// two.
    mutating func removeGradientStop(_ index: Int) {
        editGradientEverywhere { gradient in
            guard gradient.stops.count > 2, gradient.stops.indices.contains(index) else { return gradient }
            var fewer = gradient
            fewer.stops.remove(at: index)
            return fewer
        }
    }
}
