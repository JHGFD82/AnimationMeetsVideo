import CoreMedia
import SwiftUI

/// A Text effect's settings in the inspector (see docs/graphic-layers.md,
/// "Text"), grouped as Illustrator's panels are: its words, typed in place;
/// Character (font and style, size, leading, kerning, tracking, scale,
/// baseline shift, rotation, case, underline and strikethrough);
/// Paragraph (alignment, indents, space between paragraphs, wrap width,
/// anchor, hyphenation); Path; and OpenType (ligatures, figures,
/// alternates, ordinals, fractions, swash, stylistic sets).
///
/// All but the words and font are the effect's own controls, laid out as
/// Illustrator lays them out: numbers as fields with icons, two to a row;
/// small choices and on-or-off settings as icon buttons. They are set
/// outright here, not keyframed: one animated in the effects panel shows
/// its value at the playhead read-only (`InspectorControlRow`). With
/// letters selected in the words, Character styles them apart instead
/// (`TextSelectionRows`). Its fill and stroke follow in
/// `PaintInspectorGroup`.
///
/// Driven by the `Effect` it is given alone, wherever in a clip that is.
struct TextInspectorGroup: View {
    let effect: Effect
    /// Put before each group's title when the clip draws more than one
    /// shape: the effect's name.
    let prefix: String?
    /// The playhead in the clip's source time, snapped to a frame.
    let playhead: PlayheadTime
    let onEdit: ((inout Effect) -> Void) -> Void
    /// Moves the playhead to a time in the clip's source time.
    let onSeek: (CMTime) -> Void

    /// The letters selected in the words.
    @State private var selection: NSRange

    init(
        effect: Effect, prefix: String?, playhead: PlayheadTime, onEdit: @escaping ((inout Effect) -> Void) -> Void,
        onSeek: @escaping (CMTime) -> Void, selection: NSRange = NSRange(location: 0, length: 0)
    ) {
        self.effect = effect
        self.prefix = prefix
        self.playhead = playhead
        self.onEdit = onEdit
        self.onSeek = onSeek
        _selection = State(initialValue: selection)
    }

    private var content: TextContent { effect.text ?? TextContent() }

    private func title(_ section: String) -> String {
        prefix.map { "\($0) · \(section)" } ?? section
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.group) {
            InspectorGroup(title("Text")) {
                TextWordsEditor(content: content, selection: $selection) { edited in onEdit { $0.text = edited } }
                    .frame(minHeight: 56, maxHeight: 120)
                    .background(Design.Surface.base.color, in: RoundedRectangle(cornerRadius: Design.Radius.control))
                    .help("The words the layer draws; Return starts a new paragraph. Select letters to style them apart.")
            }
            InspectorGroup(title("Character")) {
                if selection.length > 0, selection.location < content.length {
                    selectedLetters
                } else {
                    FontPickerRows(fontName: content.fontName) { name in onEdit { $0.text?.fontName = name } }
                    FontAxisRows(
                        fontName: content.fontName, content: content, playhead: playhead,
                        onChange: { change in onEdit { effect in if effect.text != nil { change(&effect.text!) } } }
                    )
                    missingFontNote(content.fontName)
                    grid([[.fontSize, .leading], [.kerning, .tracking], [.verticalScale, .horizontalScale], [.baselineShift, .characterRotation]])
                    pairKerning
                    HStack(spacing: Design.Space.step) {
                        cell(.textCase)
                        PanelToggleStrip(
                            name: "Decoration", items: [toggle(.underline, glyph: .symbol("underline")), toggle(.strikethrough, glyph: .symbol("strikethrough"))]
                        )
                    }
                }
            }
            InspectorGroup(title("Paragraph")) {
                cell(.textAlign)
                grid([[.leftIndent, .rightIndent], [.firstLineIndent, .wrapWidth], [.spaceBefore, .spaceAfter]])
                HStack(alignment: .center, spacing: Design.Space.step) {
                    controls([.textAnchor])
                    controls([.hyphenate])
                }
            }
            InspectorGroup(title("Path")) {
                HStack(spacing: Design.Space.step) {
                    controls([.textOnPath, .pathFlip])
                    cell(.pathOffset)
                }
                note("On, the text follows the outline of the shape above it in the effects, from Path Offset along it.")
            }
            InspectorGroup(title("OpenType")) {
                controls([.ligatures])
                figures
                HStack(spacing: Design.Space.step) {
                    PanelToggleStrip(
                        name: "OpenType features",
                        items: InspectorGlyphs.openTypeToggles.filter { effect.control($0.kind) != nil }.map { toggle($0.kind, glyph: $0.glyph) }
                    )
                    cell(.stylisticSet)
                }
                note("A font without one of these draws as if it were off.")
            }
        }
    }

    /// The selected letters' own settings, and the block's that can't be
    /// set apart.
    @ViewBuilder
    private var selectedLetters: some View {
        let time = playhead.now
        let block = TextOutline.Setting(effect, at: time) ?? TextOutline.Setting(string: content.string, fontName: content.fontName, size: 1)
        let style = content.style(at: selection.location)
        HStack {
            Text("\(selection.length) letter\(selection.length == 1 ? "" : "s") selected")
                .font(Design.Typeface.bodyEmphasis)
                .foregroundStyle(Design.textPrimary)
            Spacer()
            Button("Clear Styling") { changeSelection { $0 = .none } }
                .controlSize(.small)
                .disabled(!content.runs.contains { NSIntersectionRange($0.range, selection).length > 0 })
                .help("Give the selected letters the block's settings")
        }
        TextSelectionRows(
            style: style, block: block,
            blockFill: effect.control(.fill)?.values(at: time) ?? [1, 1, 1, 1],
            blockStroke: effect.control(.stroke)?.values(at: time) ?? [0, 0, 0, 1],
            blockStrokeWidth: ShapeStroke(geometryOf: effect, at: time).width,
            playhead: playhead, onSeek: onSeek, onChange: changeSelection
        )
        missingFontNote(style.fontName ?? content.fontName)
        note("Leading, Kerning and Character Rotation are the whole block's:")
        grid([[.leading, .kerning], [.characterRotation]])
    }

    /// Kerning set by hand between the two letters either side of the
    /// cursor, as in Illustrator, when it is between two.
    @ViewBuilder
    private var pairKerning: some View {
        if selection.length == 0, let pair = content.kerningPair(at: selection.location) {
            let text = content.string as NSString
            let first = text.substring(with: pair)
            let second = text.substring(with: text.rangeOfComposedCharacterSequence(at: selection.location))
            TextRunNumberRow(
                name: "Kern \u{201C}\(first)\(second)\u{201D}", own: content.style(at: pair.location).kerning, block: 0, unit: "",
                range: -1000...10_000, playhead: playhead, onSeek: onSeek,
                onChange: { change in onEdit { $0.text?.changeStyle(in: pair) { change(&$0.kerning) } } }
            )
            .help("Thousandths of an em between these two letters, besides the font's kerning and the tracking")
        }
    }

    private func changeSelection(_ change: (inout TextRunStyle) -> Void) {
        let range = selection
        onEdit { $0.text?.changeStyle(in: range, change) }
    }

    @ViewBuilder
    private func missingFontNote(_ fontName: String) -> some View {
        if !FontCatalog.isInstalled(fontName) {
            Text("\u{201C}\(fontName)\u{201D} isn't installed on this Mac, so it draws with \(FontCatalog.familyAndStyle(of: fontName).family) until it is.")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Design.Typeface.label)
            .foregroundStyle(Design.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Controls

    private func controls(_ kinds: [ControlKind]) -> some View {
        InspectorControls(effect: effect, kinds: kinds, playhead: playhead, onEdit: onEdit, onSeek: onSeek)
    }

    /// A control without its name: a field with its icon, or its icon
    /// buttons (`InspectorControlRow.Layout.cell`).
    @ViewBuilder
    private func cell(_ kind: ControlKind) -> some View {
        if let control = effect.control(kind) {
            InspectorControlRow(
                control: control, playhead: playhead, layout: .cell,
                onEdit: { change in onEdit { $0.changeControl(kind, change) } }, onSeek: onSeek
            )
        }
    }

    /// Controls as cells, two to a row, as Illustrator's Character and
    /// Paragraph panels lay out their numbers.
    private func grid(_ rows: [[ControlKind]]) -> some View {
        Grid(horizontalSpacing: Design.Space.step, verticalSpacing: Design.Space.close) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.self) { cell($0) }
                    if rows[row].count == 1 { Color.clear.gridCellUnsizedAxes(.vertical) }
                }
            }
        }
    }

    /// An on-or-off control as a button of a `PanelToggleStrip`.
    private func toggle(_ kind: ControlKind, glyph: PanelGlyph) -> PanelToggleStrip.Item {
        PanelToggleStrip.Item(
            glyph: glyph, name: kind.name, isOn: effect.control(kind)?.choice == OnOff.on.rawValue,
            set: { isOn in onEdit { $0.changeControl(kind) { $0.choice = (isOn ? OnOff.on : .off).rawValue } } }
        )
    }

    /// Figures as InDesign splits them: spacing (the font's default,
    /// tabular or proportional), then for either of the last two, lining
    /// or oldstyle.
    @ViewBuilder
    private var figures: some View {
        if let control = effect.control(.figures) {
            let picked = control.choice.flatMap(TextFigures.init(rawValue:)) ?? .default
            let tabular = picked == .tabularLining || picked == .tabularOldstyle
            let oldstyle = picked == .tabularOldstyle || picked == .proportionalOldstyle
            let set: (TextFigures) -> Void = { figures in onEdit { $0.changeControl(.figures) { $0.choice = figures.rawValue } } }
            InspectorLabelledRow("Figures") {
                PanelSegmentedPicker(
                    name: "Figure spacing",
                    segments: [
                        PanelSegment(value: 0, glyph: .text("Auto"), name: "Default Figures"),
                        PanelSegment(value: 1, glyph: .text("Tabular"), name: "Tabular Figures"),
                        PanelSegment(value: 2, glyph: .text("Proportional"), name: "Proportional Figures"),
                    ],
                    selection: picked == .default ? 0 : tabular ? 1 : 2
                ) { spacing in
                    switch spacing {
                    case 1: set(oldstyle ? .tabularOldstyle : .tabularLining)
                    case 2: set(oldstyle ? .proportionalOldstyle : .proportionalLining)
                    default: set(.default)
                    }
                }
            }
            InspectorLabelledRow("") {
                PanelSegmentedPicker(
                    name: "Figure style",
                    segments: [
                        PanelSegment(value: false, glyph: .text("Lining"), name: "Lining Figures"),
                        PanelSegment(value: true, glyph: .text("Oldstyle"), name: "Oldstyle Figures"),
                    ],
                    selection: oldstyle
                ) { old in
                    set(tabular ? (old ? .tabularOldstyle : .tabularLining) : (old ? .proportionalOldstyle : .proportionalLining))
                }
                .disabled(picked == .default)
                .help(picked == .default ? "Pick Tabular or Proportional to choose lining or oldstyle figures" : "Lining or oldstyle figures")
            }
        }
    }
}
