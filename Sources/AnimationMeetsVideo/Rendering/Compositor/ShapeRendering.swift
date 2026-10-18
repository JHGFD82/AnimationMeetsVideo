import CoreGraphics
import CoreImage
import Foundation

/// Draws shapes with Core Graphics at the size they end up, so a shape
/// scaled up by the moves after it in the stack is as sharp as one made
/// that size (see docs/graphic-layers.md, "Staying sharp").
enum ShapeRendering {
    /// A shape and where it ends up: `transform` takes the frame's pixels
    /// (origin top left) to output pixels (origin bottom left), and `alpha`
    /// is the opacity of the steps after it.
    struct Placed {
        var shape: ShapeStep
        var transform: CGAffineTransform
        var alpha = 1.0
    }

    /// Colors are drawn as they are given, the timeline's encoded values,
    /// so the context and the colors share one space and nothing converts.
    private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// `shapes` drawn in order, the first at the bottom, in output pixels and
    /// kept to `canvas`. Nil when nothing of them is inside it.
    static func draw(_ shapes: [Placed], within canvas: CGRect) -> CIImage? {
        // A pixel of room for the edges' smoothing.
        let reach = shapes.reduce(CGRect.null) { $0.union($1.shape.drawnBounds.applying($1.transform)) }.insetBy(dx: -1, dy: -1)
        let bounds = reach.intersection(canvas).integral
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else { return nil }
        // Floats, so HDR timelines' values above 1 in other steps aren't
        // the only ones kept: smooth edges have no banding either.
        guard let context = CGContext(
            data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 32, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        for placed in shapes where placed.alpha > 0 {
            let shape = placed.shape
            context.saveGState()
            context.concatenate(placed.transform)
            context.setAlpha(min(placed.alpha, 1))
            if let fill = shape.fill, let color = color(fill) {
                context.addPath(shape.path)
                context.setFillColor(color)
                context.fillPath()
            }
            if let stroke = shape.stroke, let color = color(stroke) {
                context.addPath(shape.path)
                // In the frame's pixels, so it scales with the shape.
                context.setLineWidth(shape.strokeWidth)
                context.setStrokeColor(color)
                context.strokePath()
            }
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }

    private static func color(_ rgba: [Double]) -> CGColor? {
        guard rgba.count == 4 else { return nil }
        return CGColor(colorSpace: space, components: rgba.map { CGFloat($0) })
    }
}
