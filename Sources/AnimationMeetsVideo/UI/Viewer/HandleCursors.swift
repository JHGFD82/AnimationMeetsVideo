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
        }
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
