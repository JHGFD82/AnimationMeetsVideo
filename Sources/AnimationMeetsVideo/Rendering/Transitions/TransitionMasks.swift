import CoreGraphics
import CoreImage
import Foundation

/// The masks the wipes reveal the next picture through: white where it
/// shows, black where the picture before still does. Each is drawn with
/// Core Graphics, at most 640 points wide, and scaled up smoothly to the
/// output, which also softens its edges a little.
enum TransitionMasks {
    /// A shape growing from `center` until it covers the frame.
    static func iris(_ shape: IrisShape, center: CGPoint, progress: Double, in bounds: CGRect) -> CIImage {
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY),
        ]
        return draw(in: bounds) { context in
            switch shape {
            case .circle:
                let reach = corners.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 0
                let r = reach * progress
                context.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            case .diamond:
                let reach = corners.map { abs($0.x - center.x) + abs($0.y - center.y) }.max() ?? 0
                let r = reach * progress
                context.move(to: CGPoint(x: center.x, y: center.y + r))
                context.addLine(to: CGPoint(x: center.x + r, y: center.y))
                context.addLine(to: CGPoint(x: center.x, y: center.y - r))
                context.addLine(to: CGPoint(x: center.x - r, y: center.y))
                context.closePath()
                context.fillPath()
            case .box:
                let reach = corners.map { max(abs($0.x - center.x), abs($0.y - center.y)) }.max() ?? 0
                let r = reach * progress
                context.fill(CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            }
        }
    }

    /// A hand sweeping clockwise around `center` from twelve o'clock.
    static func clock(center: CGPoint, progress: Double, in bounds: CGRect) -> CIImage {
        draw(in: bounds) { context in
            guard progress > 0 else { return }
            guard progress < 1 else {
                context.fill(bounds)
                return
            }
            let reach = 2 * hypot(bounds.width, bounds.height)
            let top = CGFloat.pi / 2
            context.move(to: center)
            let sweep = CGFloat(2 * Double.pi * progress)
            context.addArc(center: center, radius: reach, startAngle: top, endAngle: top - sweep, clockwise: true)
            context.closePath()
            context.fillPath()
        }
    }

    /// `count` strips across the way the wipe moves, each opening from the
    /// side it moves away from.
    static func blinds(_ direction: TransitionDirection, count: Int, progress: Double, in bounds: CGRect) -> CIImage {
        draw(in: bounds) { context in
            let n = max(count, 1)
            for index in 0..<n {
                let i = CGFloat(index), share = CGFloat(n)
                var strip: CGRect
                if direction.isHorizontal {
                    let width = bounds.width / share
                    strip = CGRect(x: bounds.minX + i * width, y: bounds.minY, width: width, height: bounds.height)
                    let open = width * progress
                    strip.origin.x += direction == .right ? 0 : width - open
                    strip.size.width = open
                } else {
                    let height = bounds.height / share
                    strip = CGRect(x: bounds.minX, y: bounds.minY + i * height, width: bounds.width, height: height)
                    let open = height * progress
                    // Up is toward the top of the frame, where y is larger.
                    strip.origin.y += direction == .up ? 0 : height - open
                    strip.size.height = open
                }
                context.fill(strip)
            }
        }
    }

    /// Square-ish cells, `columns` across, each fading to the next picture
    /// over 30% of the transition at its own time.
    static func grid(columns: Int, order: GridOrder, progress: Double, in bounds: CGRect) -> CIImage {
        draw(in: bounds) { context in
            let cols = max(columns, 1)
            let rows = max(1, Int((Double(cols) * bounds.height / max(bounds.width, 1)).rounded()))
            let width = bounds.width / CGFloat(cols), height = bounds.height / CGFloat(rows)
            let span = 0.3
            for row in 0..<rows {
                for col in 0..<cols {
                    let start: Double
                    switch order {
                    case .random:
                        start = (1 - span) * unitRandom(row * cols + col)
                    case .diagonal:
                        let steps = max(cols + rows - 2, 1)
                        start = (1 - span) * Double(col + row) / Double(steps)
                    }
                    let level = TransitionRenderer.ramp(progress, from: start, to: start + span)
                    guard level > 0 else { continue }
                    context.setFillColor(gray: level, alpha: 1)
                    // Rows count from the top of the frame.
                    let y = bounds.maxY - CGFloat(row + 1) * height
                    context.fill(CGRect(x: bounds.minX + CGFloat(col) * width, y: y, width: width, height: height))
                }
            }
        }
    }

    /// A fixed number from 0 up to 1 for `index`, the same every time.
    static func unitRandom(_ index: Int) -> Double {
        var z = UInt64(bitPattern: Int64(index)) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// A mask drawn in `bounds`' coordinates: black, with `body` filling in
    /// white (or the gray it sets).
    static func draw(in bounds: CGRect, _ body: (CGContext) -> Void) -> CIImage {
        let scale = min(1, 640 / max(bounds.width, 1))
        let width = max(1, Int((bounds.width * scale).rounded(.up)))
        let height = max(1, Int((bounds.height * scale).rounded(.up)))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return CIImage(color: .black).cropped(to: bounds)
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        body(context)
        guard let image = context.makeImage() else { return CIImage(color: .black).cropped(to: bounds) }
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
                .concatenating(CGAffineTransform(translationX: bounds.minX, y: bounds.minY)))
            .cropped(to: bounds)
    }
}
