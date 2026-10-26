import CoreMedia
import SwiftUI

/// A Text effect's settings in the inspector (see docs/graphic-layers.md,
/// "Text"), grouped as Illustrator's panels are: its words, typed in place;
/// Character (font and style, size, leading, kerning, tracking, scale,
/// baseline shift, rotation, case, underline and strikethrough);
/// Paragraph (alignment, indents, space between paragraphs, wrap width);
/// and OpenType (ligatures, alternates, figures, fractions, ordinals,
/// swash, stylistic sets). All but the words and font are the effect's own
/// controls, so a number set here at the playhead is a keyframe there once
/// it is animated, as in the effects panel. With letters selected in the
/// words, Character styles them apart instead (`TextSelectionRows`). Its
/// fill and stroke follow in `PaintInspectorGroup`.
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
                        onChange: { change in onEdit { effect in if effect.text != nil { change(&effect.text!) } } },
                        onSeek: onSeek
                    )
                    missingFontNote(content.fontName)
                    let kerning = (EffectKind.characterControls.firstIndex(of: .kerning) ?? 0) + 1
                    controls(Array(EffectKind.characterControls.prefix(kerning)))
                    pairKerning
                    controls(Array(EffectKind.characterControls.dropFirst(kerning)))
                }
            }
            InspectorGroup(title("Paragraph")) {
                controls(EffectKind.paragraphControls)
            }
            InspectorGroup(title("Path")) {
                controls(EffectKind.pathControls)
                Text("On, the text follows the outline of the shape above it in the effects, from Path Offset along it.")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            InspectorGroup(title("OpenType")) {
                controls(EffectKind.openTypeControls)
                Text("A font without one of these draws as if it were off.")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            style: style, letter: block.letterStyle(style),
            blockFill: effect.control(.fill)?.values(at: time) ?? [1, 1, 1, 1],
            blockStroke: effect.control(.stroke)?.values(at: time) ?? [0, 0, 0, 1],
            onChange: changeSelection
        )
        missingFontNote(style.fontName ?? content.fontName)
        Text("Leading, Kerning and Character Rotation are the whole block's:")
            .font(Design.Typeface.label)
            .foregroundStyle(Design.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        controls([.leading, .kerning, .characterRotation])
    }

    /// Kerning set by hand between the two letters either side of the
    /// cursor, as in Illustrator, when it is between two.
    @ViewBuilder
    private var pairKerning: some View {
        if selection.length == 0, let pair = content.kerningPair(at: selection.location) {
            let text = content.string as NSString
            let first = text.substring(with: pair)
            let second = text.substring(with: text.rangeOfComposedCharacterSequence(at: selection.location))
            let kerning = content.style(at: pair.location).kerning
            HStack(spacing: 4) {
                Color.clear.frame(width: 18, height: 1)
                Text("Kern \u{201C}\(first)\(second)\u{201D}")
                    .foregroundStyle(Design.textSecondary)
                    .lineLimit(1)
                    .frame(width: InspectorControlRow.nameWidth, alignment: .leading)
                NumericField(value: kerning ?? 0, dragStep: 1, dragRange: -1000...10_000, accessibilityName: "Kerning between \(first) and \(second)") { value in
                    let kept = value.clamped(between: -1000, and: 10_000)
                    onEdit { $0.text?.changeStyle(in: pair) { $0.kerning = kept == 0 ? nil : kept } }
                }
                Spacer(minLength: 4)
            }
            .font(Design.Typeface.label)
            .help("Thousandths of an em between these two letters, besides the font's kerning and the tracking")
        }
    }

    private func changeSelection(_ change: (inout TextStyle) -> Void) {
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

    private func controls(_ kinds: [ControlKind]) -> some View {
        InspectorControls(effect: effect, kinds: kinds, playhead: playhead, onEdit: onEdit, onSeek: onSeek)
    }
}
