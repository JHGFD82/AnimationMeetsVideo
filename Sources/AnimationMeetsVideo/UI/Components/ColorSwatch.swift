import AppKit
import SwiftUI

/// A color's dot as a picture of its own, for menus: a menu draws a
/// symbol as a template, in the menu's own text color, whatever
/// `foregroundStyle` asked, so every swatch of a palette came out the
/// same. This draws the color itself, with a hairline rim so a light or
/// dark one reads on the menu, and a check when it is the one picked.
@MainActor
enum ColorSwatch {
    private static var cache: [String: NSImage] = [:]

    /// The swatch of `color`, `side` points across.
    static func image(_ color: BarColor, checked: Bool = false, side: CGFloat = 14) -> NSImage {
        let key = "\(color.hex)\(checked ? "✓" : "")@\(side)"
        if let cached = cache[key] { return cached }
        let fill = NSColor(Design.color(color))
        let check = color.luminance > 0.45 ? NSColor.black : NSColor.white
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            fill.setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            dot.lineWidth = 0.75
            dot.stroke()
            if checked {
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: rect.width * 0.28, y: rect.height * 0.52))
                mark.line(to: NSPoint(x: rect.width * 0.44, y: rect.height * 0.68))
                mark.line(to: NSPoint(x: rect.width * 0.74, y: rect.height * 0.34))
                mark.lineWidth = 1.6
                mark.lineCapStyle = .round
                mark.lineJoinStyle = .round
                check.setStroke()
                mark.stroke()
            }
            return true
        }
        // Drawn in its own colors, not as a template.
        image.isTemplate = false
        cache[key] = image
        return image
    }
}
