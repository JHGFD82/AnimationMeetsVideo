import AppKit
import SwiftUI

/// Bevels, grooves and panel fills: how `Design.Surface` becomes pixels.
///
/// There is one light source, top-left, and it never moves. A surface that
/// stands proud of its neighbour is lit along its top edge and shaded along
/// its bottom; a surface you look into is shaded along its top instead.
/// Keeping that consistent is what lets depth carry meaning rather than
/// just texture — a bevel in this app always means "you can operate this".
///
/// Bevels, rims and grooves are drawn over what they decorate, so each is
/// drawn with hit testing off, leaving clicks and drags at an edge to the
/// control underneath, and hidden from VoiceOver, which has nothing to read
/// in them.

// MARK: - Rails and panels

extension View {
    /// A full-width bar you operate: the toolbar, a panel's title row, the
    /// transport. Lit on top, shaded and ruled underneath.
    func rail(_ level: Design.Surface = .raised) -> some View {
        background(level.color)
            .overlay(alignment: .top) { Design.bevelLight.frame(height: 1).decorative() }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    Design.bevelShade.frame(height: 1)
                    Design.hairline.frame(height: 1)
                }
                .decorative()
            }
    }

    /// The body of a panel: a flat fill at one level, no bevel of its own.
    /// Panels get their edges from the grooves between them.
    func panelSurface(_ level: Design.Surface = .base) -> some View {
        background(level.color)
    }

    /// A recessed area you look into — the track area, a list body. Shaded
    /// along the top so it reads as sunk below the rail above it.
    func sunken(_ level: Design.Surface = .sunken) -> some View {
        background(level.color)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.black.opacity(0.35), Color.black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 4)
                .decorative()
            }
    }

    /// A sheet or popover body: the top of the ladder, with a lit rim so it
    /// separates from whatever it covers.
    func floatingSurface(radius: CGFloat = Design.Radius.sheet) -> some View {
        background(Design.Surface.floating.color)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Design.bevelEdge, lineWidth: 1)
                    .decorative()
            }
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
    }

    /// Drawn for looks alone: it takes no clicks and VoiceOver skips it.
    func decorative() -> some View {
        allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension Design {
    /// The rim of a raised shape: lit at the top, shaded at the bottom,
    /// which is the whole bevel in one stroke.
    static var bevelEdge: LinearGradient {
        LinearGradient(
            colors: [bevelLight, Color.white.opacity(0.02), Color.black.opacity(0.28)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The same, stronger, for things meant to read as solid blocks.
    static var bevelEdgeStrong: LinearGradient {
        LinearGradient(
            colors: [bevelLightStrong, Color.white.opacity(0.04), Color.black.opacity(0.4)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// A clip's body: a tinted block lit from above.
    ///
    /// Clip names and badges are drawn on it in `textOnColor`, at least 90%
    /// strong. Over the track's rows, plain or lit as a drop target, that
    /// reads at 4.5:1 or better for every tone where the text sits (the
    /// middle of the block). Unselected it does as it is; selected, the
    /// brighter fill only managed 3.3:1, so it is shaded by a fifth, the
    /// same as laying 20% black over it. It stays brighter than unselected,
    /// and the selected outline still marks it.
    ///
    /// A clip turned off is drawn in `tone.greyed()`, here and in its
    /// outline, rather than through a saturation filter over the whole
    /// block, which costs a compositing pass even when it does nothing.
    static func clipFill(_ tone: Color, selected: Bool, enabled: Bool = true) -> LinearGradient {
        let tone = enabled ? tone : tone.greyed()
        return LinearGradient(
            colors: selected
                ? [tone.darkened(to: 0.786).opacity(0.936), tone.darkened(to: 0.725).opacity(0.728)]
                : [tone.opacity(0.62), tone.opacity(0.4)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Grooves

/// The line between two surfaces: a dark cut with a lit edge below it, so
/// it reads as engraved rather than drawn on. Replaces `Divider()`
/// throughout the editor.
struct Groove: View {
    enum Axis { case horizontal, vertical }

    var axis: Axis = .horizontal
    /// Layer separators inside the track area are quieter than the grooves
    /// between whole panels.
    var subtle = false

    var body: some View {
        lines.decorative()
    }

    @ViewBuilder
    private var lines: some View {
        let dark = Design.hairline.opacity(subtle ? 0.6 : 1)
        let light = Color.white.opacity(subtle ? 0.03 : 0.06)
        switch axis {
        case .horizontal:
            VStack(spacing: 0) {
                dark.frame(height: 1)
                light.frame(height: 1)
            }
            .frame(height: 2)
        case .vertical:
            HStack(spacing: 0) {
                dark.frame(width: 1)
                light.frame(width: 1)
            }
            .frame(width: 2)
        }
    }
}

extension View {
    /// A groove down one side of a column, for the library/viewer/inspector
    /// seams where a `Divider()` would be a single flat line.
    func grooved(_ edge: HorizontalEdge) -> some View {
        overlay(alignment: edge == .leading ? .leading : .trailing) {
            Groove(axis: .vertical)
        }
    }
}

// MARK: - Chips and controls

extension View {
    /// A small raised block: a transition tile, a section, a status pill.
    func beveledChip(
        fill: Color,
        radius: CGFloat = Design.Radius.control,
        strong: Bool = false
    ) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(strong ? Design.bevelEdgeStrong : Design.bevelEdge, lineWidth: 1)
                    .decorative()
            }
    }

    /// Marks a row, or a group of rows, as selected: outlined all the way
    /// round, as a selected clip is, over a faint lift, so what Delete or
    /// Copy would take is plain. In a panel that isn't the active one the
    /// outline is grey, as the Mac draws a selection that isn't where the
    /// keys go (`EditorPanel`).
    func selectedRow(_ isSelected: Bool) -> some View {
        modifier(SelectionOutline(isSelected: isSelected))
    }
}

extension EnvironmentValues {
    /// Whether the view is in the editor's active panel, the one the keys
    /// and the Edit menu go to first. True outside the editor's panels.
    @Entry var isInActivePanel = true
}

private struct SelectionOutline: ViewModifier {
    let isSelected: Bool
    @Environment(\.isInActivePanel) private var isActive

    func body(content: Content) -> some View {
        let tone = isActive ? Design.accent : Design.textTertiary
        content
            .background(isSelected ? tone.opacity(0.14) : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(tone, lineWidth: 1.5)
                    .opacity(isSelected ? 1 : 0)
                    .decorative()
            }
    }
}

extension Color {
    /// This color as the grey of the same lightness (Rec. 709 luma), for
    /// what is turned off.
    func greyed() -> Color {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return self }
        let luma = 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
        return Color(.sRGB, white: luma, opacity: srgb.alphaComponent)
    }
}

private extension Color {
    /// This color with its red, green and blue scaled by `fraction`, which
    /// darkens it without changing its hue.
    func darkened(to fraction: Double) -> Color {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return self }
        return Color(
            .sRGB,
            red: srgb.redComponent * fraction,
            green: srgb.greenComponent * fraction,
            blue: srgb.blueComponent * fraction,
            opacity: srgb.alphaComponent
        )
    }
}
