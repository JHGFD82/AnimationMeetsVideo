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
    static func clipFill(_ tone: Color, selected: Bool) -> LinearGradient {
        LinearGradient(
            colors: selected
                ? [tone.opacity(0.92), tone.opacity(0.66)]
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

    /// Marks a row as selected without washing it in tint: a solid accent
    /// bar down its leading edge and a faint lift across the row.
    func selectedRow(_ isSelected: Bool) -> some View {
        background(isSelected ? Design.accent.opacity(0.16) : .clear)
            .overlay(alignment: .leading) {
                Design.accent
                    .frame(width: 2)
                    .opacity(isSelected ? 1 : 0)
                    .decorative()
            }
    }
}
