import CoreGraphics
import Foundation

/// A Fill or Stroke's gradient at one moment, before it is placed: its
/// points and stops, and how it paints them (see docs/gradients.md).
struct GradientFill: Equatable, Sendable {
    var gradient: PaintGradient
    var style: PaintStyle

    /// Placed on `item` (the shape's bounds) or `frame`, as its style says,
    /// both in the frame's pixels.
    func placed(item: CGRect, frame: CGRect) -> GradientPaint {
        GradientPaint(fill: self, bounds: style.space == .frame ? frame : item)
    }

    /// What it paints, in words, for a render's key.
    var keyText: String {
        func n(_ value: Double) -> String { String(format: "%.5f", value) }
        return "g\(style.kind.rawValue)/\(style.repeats.rawValue)/\(style.blend.rawValue)/\(style.space.rawValue) "
            + gradient.values.map(n).joined(separator: ",")
    }
}

/// A gradient placed to paint: its points are shares of `bounds`, in the
/// frame's pixels.
struct GradientPaint: Equatable, Sendable {
    var fill: GradientFill
    var bounds: CGRect
}

/// Draws gradients with Core Graphics, clipped to a fill or stroke's area
/// by the caller, in the float context `ShapeRendering` draws shapes in.
enum GradientRendering {
    /// Colors taken along one length of a gradient, enough that a slow one
    /// shows no steps.
    static let samplesPerLength = 256
    /// The most lengths a repeating gradient is drawn over.
    static let mostLengths = 64

    /// Draws `paint` over `area` (in the frame's pixels, which the context
    /// draws in), past its ends as its style says.
    static func draw(_ paint: GradientPaint, in context: CGContext, covering area: CGRect, space: CGColorSpace) {
        let gradient = paint.fill.gradient, style = paint.fill.style
        let bounds = paint.bounds
        func point(_ unit: CGPoint) -> CGPoint {
            CGPoint(x: bounds.minX + unit.x * bounds.width, y: bounds.minY + unit.y * bounds.height)
        }
        let start = point(gradient.start), end = point(gradient.end)
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        let length = (dx * dx + dy * dy).squareRoot()
        let corners = [
            CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
            CGPoint(x: area.minX, y: area.maxY), CGPoint(x: area.maxX, y: area.maxY),
        ]
        let one = gradient.samples(samplesPerLength, blend: style.blend)
        // With no length there is no direction: its end color everywhere.
        guard length > 1e-6 else {
            let color = gradient.sortedStops.last?.color ?? [0, 0, 0, 0]
            context.setFillColor(CGColor(colorSpace: space, components: color.map { CGFloat($0) }) ?? CGColor(gray: 0, alpha: 0))
            context.fill(area)
            return
        }
        switch style.kind {
        case .linear:
            // How far along the gradient the area reaches, in lengths.
            let reach = corners.map { (Double($0.x - start.x) * dx + Double($0.y - start.y) * dy) / (length * length) }
            let (low, high) = span(reach.min() ?? 0, reach.max() ?? 1, style.repeats)
            guard let cg = cgGradient(one, from: low, to: high, repeats: style.repeats, space: space) else { return }
            context.drawLinearGradient(
                cg,
                start: CGPoint(x: Double(start.x) + dx * low, y: Double(start.y) + dy * low),
                end: CGPoint(x: Double(start.x) + dx * high, y: Double(start.y) + dy * high),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        case .radial:
            // In the ellipse's own space: the center at the origin, along
            // the edge point's direction, a circle of the gradient's radius.
            let aspect = max(gradient.aspect, 0.01)
            let local = CGAffineTransform(translationX: start.x, y: start.y)
                .rotated(by: atan2(dy, dx))
                .scaledBy(x: 1, y: aspect)
            let back = local.inverted()
            let focal = CGPoint(x: Double(gradient.focal.x) * length, y: Double(gradient.focal.y) * length)
            let farthest = corners.map { corner -> Double in
                let p = corner.applying(back)
                return (Double(p.x) * Double(p.x) + Double(p.y) * Double(p.y)).squareRoot() / length
            }.max() ?? 1
            let offset = (Double(focal.x * focal.x + focal.y * focal.y)).squareRoot() / length
            let (_, high) = span(0, farthest + offset, style.repeats)
            guard let cg = cgGradient(one, from: 0, to: high, repeats: style.repeats, space: space) else { return }
            context.saveGState()
            context.concatenate(local)
            // The circles spread from the focal point to the center, and on
            // past it at the same rate for a repeat.
            let endCenter = CGPoint(x: Double(focal.x) * (1 - high), y: Double(focal.y) * (1 - high))
            context.drawRadialGradient(
                cg, startCenter: focal, startRadius: 0, endCenter: endCenter, endRadius: length * high,
                options: [.drawsAfterEndLocation]
            )
            context.restoreGState()
        case .angular:
            // Round once, from the edge point's direction; it always
            // starts again where it began.
            guard let cg = cgGradient(one, from: 0, to: 1, repeats: .hold, space: space) else { return }
            // The SDK gives this no method on CGContext, only the C call.
            CGContextDrawConicGradient(context, cg, start, atan2(dy, dx))
        }
    }

    /// The lengths to draw over, from `low` to `high` along the gradient:
    /// one length when it holds its ends, else whole lengths covering the
    /// span, at most `mostLengths`.
    static func span(_ low: Double, _ high: Double, _ repeats: GradientRepeat) -> (Double, Double) {
        guard repeats != .hold else { return (0, 1) }
        var from = floor(min(low, 0)), to = ceil(max(high, 1))
        if to - from > Double(mostLengths) {
            let middle = (from + to) / 2
            from = floor(middle - Double(mostLengths) / 2)
            to = from + Double(mostLengths)
        }
        return (from, to)
    }

    /// A Core Graphics gradient of `one` length's colors drawn from `low`
    /// to `high` lengths, repeated or reflected between.
    static func cgGradient(_ one: [[Double]], from low: Double, to high: Double, repeats: GradientRepeat, space: CGColorSpace) -> CGGradient? {
        guard one.count > 1, high > low else { return nil }
        let lengths = high - low
        let count = min(max(Int(lengths * Double(one.count)), one.count), samplesPerLength * mostLengths)
        var components: [CGFloat] = []
        var locations: [CGFloat] = []
        components.reserveCapacity(count * 4)
        locations.reserveCapacity(count)
        for i in 0..<count {
            let fraction = Double(i) / Double(count - 1)
            let position = PaintGradient.wrapped(low + lengths * fraction, repeats)
            let color = one[min(Int((position * Double(one.count - 1)).rounded()), one.count - 1)]
            components += color.map { CGFloat($0) }
            locations.append(CGFloat(fraction))
        }
        return CGGradient(colorSpace: space, colorComponents: components, locations: locations, count: count)
    }
}
