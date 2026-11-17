import AppKit

/// The pointer over each kind of handle: a resize arrow along the handle's
/// direction and a curved arrow round a corner, both turned with the box,
/// drawn from SF Symbols with a light rim so they read on any picture.
@MainActor
enum HandleCursors {
    private static var cache: [String: NSCursor] = [:]

    static func cursor(for kind: HandleCursor) -> NSCursor {
        switch kind {
        case .resize(let angle):
            return turned("arrow.left.and.right", angle: angle)
        case .rotate(let angle):
            // The symbol's arrows sweep round its top right: turned to the
            // corner or edge the zone is at.
            return turned("arrow.trianglehead.2.clockwise.rotate.90", angle: angle + .pi / 4)
        case .move:
            return turned("arrow.up.and.down.and.arrow.left.and.right", angle: 0)
        case .crosshair:
            return .crosshair
        case .slide:
            return .resizeLeftRight
        case .notAllowed:
            return .operationNotAllowed
        case .pen(let badge):
            return pen(badge)
        case .convert:
            return pen(.caret, converting: true)
        case .hand:
            return .openHand
        case .closedHand:
            return .closedHand
        }
    }

    /// The pen: a nib drawn in thin lines, its point at the top left and
    /// at the hot spot, so a click lands where the tip is; a small badge
    /// to its upper right says what a click does. Option's convert pointer
    /// is a caret whose point is the hot spot, as Illustrator's is. Drawn
    /// as vectors, sharp at any screen scale.
    private static func pen(_ badge: PenBadge, converting: Bool = false) -> NSCursor {
        let key = "pen@\(badge)\(converting ? "-convert" : "")"
        if let cached = cache[key] { return cached }
        let side = 24.0
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            if converting {
                drawConvertCaret(in: context)
            } else {
                drawNib(in: context)
                drawBadge(badge, in: context)
            }
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: tip.x, y: tip.y))
        cache[key] = cursor
        return cursor
    }

    /// Where the pen's point is, in the image (points, from the top left).
    private static let tip = CGPoint(x: 2, y: 2)

    /// A line of the pointer: a white rim under a thin black line, so it
    /// reads on any picture.
    private static func ink(_ path: CGPath, in context: CGContext, fill: Bool = false) {
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2.6)
        context.strokePath()
        if fill {
            context.addPath(path)
            context.setFillColor(NSColor.white.cgColor)
            context.fillPath()
        }
        context.addPath(path)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1.1)
        context.strokePath()
    }

    /// A pen nib with its point at `tip`, its body running down and to the
    /// right: the outline, the slit from the point and the hole it ends in,
    /// and the collar.
    private static func drawNib(in context: CGContext) {
        // Drawn pointing down from the origin, then turned 45° so it runs
        // to the bottom right, its point at `tip`.
        let place = CGAffineTransform(translationX: tip.x, y: tip.y).rotated(by: -.pi / 4)
        let outline = CGMutablePath()
        outline.move(to: .zero)
        outline.addLine(to: CGPoint(x: 4.2, y: 8.5))
        outline.addLine(to: CGPoint(x: 4.2, y: 13))
        outline.addLine(to: CGPoint(x: -4.2, y: 13))
        outline.addLine(to: CGPoint(x: -4.2, y: 8.5))
        outline.closeSubpath()
        let collar = CGMutablePath()
        collar.addRect(CGRect(x: -3.4, y: 13, width: 6.8, height: 3))
        ink(outline.copy(using: [place]), in: context, fill: true)
        ink(collar.copy(using: [place]), in: context, fill: true)
        let slit = CGMutablePath()
        slit.move(to: CGPoint(x: 0, y: 2.5))
        slit.addLine(to: CGPoint(x: 0, y: 6.6))
        slit.addEllipse(in: CGRect(x: -1.1, y: 6.6, width: 2.2, height: 2.2))
        context.addPath(slit.copy(using: [place]))
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    /// The badge, up and to the right of the nib.
    private static func drawBadge(_ badge: PenBadge, in context: CGContext) {
        let center = CGPoint(x: 19.5, y: 4.5), r = 2.4
        let mark = CGMutablePath()
        switch badge {
        case .none:
            return
        case .ring:
            mark.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        case .caret:
            mark.move(to: CGPoint(x: center.x - r, y: center.y + r * 0.6))
            mark.addLine(to: CGPoint(x: center.x, y: center.y - r * 0.6))
            mark.addLine(to: CGPoint(x: center.x + r, y: center.y + r * 0.6))
        case .slash:
            mark.move(to: CGPoint(x: center.x - r, y: center.y + r))
            mark.addLine(to: CGPoint(x: center.x + r, y: center.y - r))
        case .plus:
            mark.move(to: CGPoint(x: center.x - r, y: center.y))
            mark.addLine(to: CGPoint(x: center.x + r, y: center.y))
            mark.move(to: CGPoint(x: center.x, y: center.y - r))
            mark.addLine(to: CGPoint(x: center.x, y: center.y + r))
        case .minus:
            mark.move(to: CGPoint(x: center.x - r, y: center.y))
            mark.addLine(to: CGPoint(x: center.x + r, y: center.y))
        }
        ink(mark, in: context)
    }

    /// Option's convert pointer: a caret whose point is the hot spot.
    private static func drawConvertCaret(in context: CGContext) {
        // Its arms 40° apart, opening down and to the right, as the nib
        // runs.
        func arm(_ degrees: Double) -> CGPoint {
            CGPoint(x: tip.x + 8 * cos(degrees * .pi / 180), y: tip.y + 8 * sin(degrees * .pi / 180))
        }
        let caret = CGMutablePath()
        caret.move(to: arm(25))
        caret.addLine(to: tip)
        caret.addLine(to: arm(65))
        ink(caret, in: context)
    }

    /// The symbol turned by `angle` (radians, clockwise on screen), to the
    /// nearest 15°.
    private static func turned(_ name: String, angle: Double) -> NSCursor {
        let step = Double.pi / 12
        let steps = Int((angle / step).rounded())
        let key = "\(name)@\(((steps % 24) + 24) % 24)"
        if let cached = cache[key] { return cached }
        let cursor = make(name, angle: Double(steps) * step) ?? .arrow
        cache[key] = cursor
        return cursor
    }

    private static func make(_ name: String, angle: Double) -> NSCursor? {
        let base = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        guard let dark = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(base.applying(NSImage.SymbolConfiguration(paletteColors: [.black]))),
            let light = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(base.applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        else { return nil }
        let side: CGFloat = 26
        // Drawn now, at twice the size for a Retina screen.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.translateBy(x: side / 2, y: side / 2)
        // The image is drawn y up; the angle is clockwise on screen.
        context.rotate(by: -CGFloat(angle))
        let size = dark.size
        let rect = NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
            light.draw(in: rect.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy)))
        }
        dark.draw(in: rect)
        graphics.flushGraphics()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}

private extension CGPath {
    func copy(using transform: [CGAffineTransform]) -> CGPath {
        var matrix = transform[0]
        return copy(using: &matrix) ?? self
    }
}
