import CoreGraphics
import CoreImage
import Foundation

/// Draws shapes with Core Graphics at the size they end up, so a shape
/// scaled up by the moves after it in the stack is as sharp as one made
/// that size (see docs/graphic-layers.md, "Staying sharp"). Fills and
/// strokes alike are areas filled with a color: a stroke's area is worked
/// out from its outline first (`ShapeStroke.area`).
enum ShapeRendering {
    /// An area to fill and where it ends up: `transform` takes the frame's
    /// pixels (origin top left) to output pixels (origin bottom left), and
    /// `alpha` is the opacity of the steps after it.
    struct Paint {
        var area: CGPath
        var color: [Double]
        var transform: CGAffineTransform
        var alpha = 1.0
    }

    /// The edge of a shape drawn so far, for a Stroke below it to follow,
    /// with the same `transform` as a paint.
    struct Edge {
        var area: CGPath
        var transform: CGAffineTransform
    }

    /// Colors are drawn as they are given, the timeline's encoded values,
    /// so the context and the colors share one space and nothing converts.
    private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// `paints` filled in order, the first at the bottom, in output pixels
    /// and kept to `canvas`. Nil when nothing of them is inside it.
    static func draw(_ paints: [Paint], within canvas: CGRect) -> CIImage? {
        // A pixel of room for the edges' smoothing.
        let reach = paints.reduce(CGRect.null) { $0.union($1.area.boundingBoxOfPath.applying($1.transform)) }.insetBy(dx: -1, dy: -1)
        let bounds = reach.intersection(canvas).integral
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else { return nil }
        // Floats, so smooth edges have no banding.
        guard let context = CGContext(
            data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 32, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        for paint in paints where paint.alpha > 0 && paint.color.count == 4 {
            context.saveGState()
            context.concatenate(paint.transform)
            context.setAlpha(min(paint.alpha, 1))
            context.addPath(paint.area)
            context.setFillColor(CGColor(colorSpace: space, components: paint.color.map { CGFloat($0) }) ?? CGColor(gray: 0, alpha: 0))
            context.fillPath()
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }

    /// The edges as one area, in the frame's pixels as a shape added now
    /// would be drawn from: `current` is the transform such a shape gets.
    /// Nil when there are none.
    static func union(of edges: [Edge], current: CGAffineTransform) -> CGPath? {
        let back = current.inverted()
        var result: CGPath?
        for edge in edges {
            var toCurrent = edge.transform.concatenating(back)
            guard let area = edge.area.copy(using: &toCurrent) else { continue }
            result = result.map { $0.union(area) } ?? area
        }
        return result
    }
}
