import AppKit
import SwiftUI

/// The Mac's color picker for Other… in a bar's Color menu: it shows the
/// bar's color, and every change in it recolors the bar at once, until
/// Other… is chosen for another bar or `end()` is called. One for the
/// app, as there is one system color panel. See docs/bar-colors.md, "The
/// color picker".
///
/// What it recolors is held as IDs inside `onChange`, never views: the
/// menu that opened it is gone by the time a color arrives. A stream of
/// changes from a drag in the panel merges into one undo step, since a
/// recolor's identity leaves the color out (`ProjectChange`).
@MainActor
final class BarColorPanel: NSObject {
    static let shared = BarColorPanel()

    private var onChange: ((BarColor) -> Void)?
    /// Whether the panel sends its changes here; it has no getter to ask.
    private var isTarget = false

    /// Shows the panel on `current`, sending every change to `onChange`.
    func show(current: BarColor, onChange: @escaping (BarColor) -> Void) {
        let panel = NSColorPanel.shared
        // Let go of the last bar before moving the panel's color, so
        // showing the new bar's doesn't recolor the old one.
        self.onChange = nil
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(Design.color(current))
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        isTarget = true
        self.onChange = onChange
        panel.orderFront(nil)
    }

    /// Stops recoloring: the editor's window closed or shows another
    /// project. The panel itself stays where the person left it.
    func end() {
        onChange = nil
        guard isTarget else { return }
        isTarget = false
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let onChange, let color = BarColor(sender.color) else { return }
        onChange(color)
    }
}

extension BarColor {
    /// A color from the panel or a view, in sRGB, rounded to 8 bits a
    /// channel, as it is saved; nil when it has no sRGB form.
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
    }

    init?(_ color: Color) {
        self.init(NSColor(color))
    }
}
