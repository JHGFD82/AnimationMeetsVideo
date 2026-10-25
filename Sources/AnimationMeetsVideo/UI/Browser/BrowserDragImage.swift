import AppKit
import SwiftUI

/// What follows the pointer when clips or timelines are dragged out of the
/// browser: one thumbnail of the first thing dragged, outlined in the
/// accent, with how many are dragged when there are several. See
/// docs/browser.md, "Dragging".
enum BrowserDragImage {
    /// `picture` fitted on black, or without one (sound, or a picture not
    /// made yet) a tile of `tone` with `symbol` on it in white.
    static func make(picture: NSImage?, symbol: String, tone: NSColor, size: CGSize, count: Int) -> NSImage {
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size.height * 0.4, weight: .medium))
        return NSImage(size: size, flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect, xRadius: Design.Radius.chip, yRadius: Design.Radius.chip)
            (picture == nil ? tone : NSColor.black).setFill()
            tile.fill()
            if let picture {
                let fitted = picture.size.width > 0 && picture.size.height > 0
                    ? min(rect.width / picture.size.width, rect.height / picture.size.height) : 1
                let drawn = CGSize(width: picture.size.width * fitted, height: picture.size.height * fitted)
                picture.draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            } else if let icon {
                // Tinted white: a symbol image draws in its own colour.
                let tinted = NSImage(size: icon.size, flipped: false) { bounds in
                    icon.draw(in: bounds)
                    NSColor.white.set()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: CGRect(
                    x: rect.midX - icon.size.width / 2, y: rect.midY - icon.size.height / 2,
                    width: icon.size.width, height: icon.size.height
                ))
            }
            NSColor(Design.accent).setStroke()
            tile.lineWidth = 2
            tile.stroke()
            if count > 1 {
                let text = NSAttributedString(string: "\(count)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
                ])
                let badge = CGRect(x: rect.maxX - text.size().width - 14, y: rect.maxY - 20, width: text.size().width + 10, height: 16)
                NSColor(Design.accent).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
                text.draw(at: CGPoint(x: badge.minX + 5, y: badge.minY + (badge.height - text.size().height) / 2))
            }
            return true
        }
    }
}
