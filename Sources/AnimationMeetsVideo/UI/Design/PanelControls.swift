import SwiftUI

/// The controls of a property panel laid out as Illustrator's and
/// InDesign's are: a small choice as a strip of icon buttons rather than a
/// menu, an on-or-off setting as a button that stays lit, and a number as
/// a compact field with an icon saying what it is, two to a row.
///
/// They share one look: a sunken track (`Design.Surface.sunken`) holding
/// the buttons or the number, the picked button raised out of it on the
/// floating surface with a bevel, as a pressed key would be lifted. Every
/// button is icon-only, so each takes a name that is its VoiceOver label
/// and its help.

// MARK: - Glyphs

/// What a panel button or field shows: an SF Symbol, a few letters (as
/// Illustrator shows "fi" for ligatures or "VA" for kerning), or a small
/// drawing in the ink it is given, for what no symbol shows (a stroke's
/// join).
enum PanelGlyph {
    case symbol(String)
    case text(String)
    case drawn((inout GraphicsContext, CGSize, Color) -> Void)
}

/// A `PanelGlyph` in `ink`, sized for a 22-point button.
struct PanelGlyphView: View {
    let glyph: PanelGlyph
    var ink: Color = Design.textSecondary

    var body: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(Design.Typeface.label)
                .foregroundStyle(ink)
        case .text(let letters):
            Text(verbatim: letters)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, letters.count > 3 ? 4 : 0)
        case .drawn(let draw):
            Canvas { context, size in draw(&context, size, ink) }
                .frame(width: 16, height: 14)
        }
    }
}

extension Design {
    enum PanelControl {
        /// The height of a track, a button and a field.
        static let height: CGFloat = 22
        /// The least width of a button in a track.
        static let buttonWidth: CGFloat = 24
        /// The width of a field's icon column.
        static let glyphWidth: CGFloat = 18
    }
}

// MARK: - Tracks and buttons

/// The sunken strip panel buttons and fields sit in.
struct PanelTrack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 1) { content() }
            .padding(1)
            .frame(minHeight: Design.PanelControl.height)
            .background(Design.Surface.sunken.color, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .strokeBorder(Design.hairline.opacity(0.8), lineWidth: 1)
                    .decorative()
            }
    }
}

/// One icon button in a `PanelTrack`: raised and in primary ink while
/// `isOn`, quiet otherwise, lifting a little under the pointer.
struct PanelSegmentButton: View {
    let glyph: PanelGlyph
    /// What it does or picks, as its VoiceOver label and help: "Align
    /// Left", "Underline".
    let name: String
    let isOn: Bool
    /// Stretches to share the track's width with the others.
    var fills = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            PanelGlyphView(glyph: glyph, ink: ink)
                .frame(minWidth: Design.PanelControl.buttonWidth, maxWidth: fills ? .infinity : nil)
                .frame(height: Design.PanelControl.height - 2)
                .padding(.horizontal, 2)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: Design.Radius.control - 1, style: .continuous)
                            .fill(Design.Surface.floating.color)
                            .overlay {
                                RoundedRectangle(cornerRadius: Design.Radius.control - 1, style: .continuous)
                                    .strokeBorder(Design.bevelEdgeStrong, lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                    } else if isHovered, isEnabled {
                        RoundedRectangle(cornerRadius: Design.Radius.control - 1, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var ink: Color {
        guard isEnabled else { return Design.textTertiary.opacity(0.5) }
        return isOn || isHovered ? Design.textPrimary : Design.textSecondary
    }
}

/// One option of a `PanelSegmentedPicker`.
struct PanelSegment<Value: Hashable> {
    let value: Value
    let glyph: PanelGlyph
    let name: String
}

/// A few options as a strip of icon buttons, the picked one raised: a
/// paragraph's alignments, a stroke's joins.
struct PanelSegmentedPicker<Value: Hashable>: View {
    /// What the options set, for VoiceOver: "Alignment".
    let name: String
    let segments: [PanelSegment<Value>]
    let selection: Value
    /// Stretches the buttons to the width offered.
    var fills = false
    let onPick: (Value) -> Void

    var body: some View {
        PanelTrack {
            ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                PanelSegmentButton(glyph: segment.glyph, name: segment.name, isOn: segment.value == selection, fills: fills) {
                    onPick(segment.value)
                }
            }
        }
        .fixedSize(horizontal: !fills, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}

/// On-or-off settings side by side as buttons that stay lit while on:
/// underline and strikethrough, as Illustrator's Character panel has them.
struct PanelToggleStrip: View {
    struct Item {
        let glyph: PanelGlyph
        let name: String
        let isOn: Bool
        let set: (Bool) -> Void
    }

    let name: String
    let items: [Item]

    var body: some View {
        PanelTrack {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                PanelSegmentButton(glyph: item.glyph, name: item.name, isOn: item.isOn) { item.set(!item.isOn) }
                    .accessibilityValue(item.isOn ? "on" : "off")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}

// MARK: - Fields

/// A number's field: its icon, then the value (a `NumericField` or any
/// other content) in a sunken box, then an optional accessory such as a
/// keyframe badge. The icon's help says what the number is.
struct PanelField<Content: View, Accessory: View>: View {
    let glyph: PanelGlyph?
    /// What the number is: the icon's help.
    let name: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessory: () -> Accessory

    init(
        glyph: PanelGlyph?, name: String, @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.glyph = glyph
        self.name = name
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 4) {
            if let glyph {
                PanelGlyphView(glyph: glyph, ink: Design.textTertiary)
                    .frame(width: Design.PanelControl.glyphWidth)
                    .help(name)
                    .accessibilityHidden(true)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
        }
        .padding(.horizontal, 5)
        .frame(height: Design.PanelControl.height)
        .frame(maxWidth: .infinity)
        .background(Design.Surface.sunken.color, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                .strokeBorder(Design.hairline.opacity(0.8), lineWidth: 1)
                .decorative()
        }
    }
}

/// A menu drawn as a `PanelField`, for a choice with too many options or
/// names too long for icons (a font, kerning's method): the field's icon,
/// the picked option's name and a chevron.
struct PanelMenuField<Value: Hashable>: View {
    let glyph: PanelGlyph?
    /// What it picks: the help and VoiceOver label.
    let name: String
    let options: [(value: Value, name: String)]
    let selection: Value
    let onPick: (Value) -> Void

    var body: some View {
        Menu {
            Picker(name, selection: Binding(get: { selection }, set: onPick)) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].name).tag(options[index].value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            PanelField(glyph: glyph, name: name) {
                Text(options.first { $0.value == selection }?.name ?? "")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } accessory: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(Design.Typeface.glyphTiny)
                    .foregroundStyle(Design.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityValue(options.first { $0.value == selection }?.name ?? "")
    }
}

// MARK: - Reference point

/// The nine points of a box as a 3×3 grid of small squares, the picked one
/// filled, as Illustrator's reference point picker. `points` runs row by
/// row from the top left.
struct PanelPointGrid<Value: Hashable>: View {
    let name: String
    /// Nine values with their names ("Top Left").
    let points: [(value: Value, name: String)]
    let selection: Value
    let onPick: (Value) -> Void

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let index = row * 3 + column
                        if points.indices.contains(index) {
                            point(points[index])
                        }
                    }
                }
            }
        }
        .padding(3)
        .background(Design.Surface.sunken.color, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                .strokeBorder(Design.hairline.opacity(0.8), lineWidth: 1)
                .decorative()
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }

    private func point(_ point: (value: Value, name: String)) -> some View {
        let isOn = point.value == selection
        return Button { onPick(point.value) } label: {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isOn ? Design.textPrimary : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(isOn ? Design.textPrimary : Design.textTertiary, lineWidth: 1)
                }
                .frame(width: 7, height: 7)
                .frame(width: 13, height: 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(point.name)
        .accessibilityLabel(point.name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
