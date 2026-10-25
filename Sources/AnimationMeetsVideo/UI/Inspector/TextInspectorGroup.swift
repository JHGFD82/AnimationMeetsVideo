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
/// it is animated, as in the effects panel. Its fill and stroke follow in
/// `PaintInspectorGroup`.
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

    /// Read once: listing the Mac's fonts takes a moment.
    private static let families = FontCatalog.families()

    private var content: TextContent { effect.text ?? TextContent() }

    private func title(_ section: String) -> String {
        prefix.map { "\($0) · \(section)" } ?? section
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.group) {
            InspectorGroup(title("Text")) {
                TextEditor(text: Binding(
                    get: { content.string },
                    set: { string in onEdit { $0.text = TextContent(string: string, fontName: $0.text?.fontName ?? TextContent.defaultFontName) } }
                ))
                .font(Design.Typeface.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 56, maxHeight: 120)
                .background(Design.Surface.base.color, in: RoundedRectangle(cornerRadius: Design.Radius.control))
                .accessibilityLabel("Text")
                .help("The words the layer draws; Return starts a new paragraph")
            }
            InspectorGroup(title("Character")) {
                fontPickers
                if !FontCatalog.isInstalled(content.fontName) {
                    Text("\u{201C}\(content.fontName)\u{201D} isn't installed on this Mac, so it draws with \(FontCatalog.familyAndStyle(of: content.fontName).family) until it is.")
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                controls(EffectKind.characterControls)
            }
            InspectorGroup(title("Paragraph")) {
                controls(EffectKind.paragraphControls)
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

    private func controls(_ kinds: [ControlKind]) -> some View {
        InspectorControls(effect: effect, kinds: kinds, playhead: playhead, onEdit: onEdit, onSeek: onSeek)
    }

    // MARK: Font

    @ViewBuilder
    private var fontPickers: some View {
        let shown = FontCatalog.familyAndStyle(of: content.fontName)
        let styles = FontCatalog.styles(ofFamily: shown.family)
        labelled("Font") {
            Picker("Font", selection: Binding(
                get: { shown.family },
                set: { family in
                    guard let name = FontCatalog.fontName(inFamily: family, like: content.fontName) else { return }
                    setFont(name)
                }
            )) {
                ForEach(Self.families, id: \.self) { Text($0).tag($0) }
            }
        }
        labelled("Style") {
            Picker("Style", selection: Binding(get: { content.fontName }, set: setFont)) {
                // A missing font is kept, under its own name, until another
                // is picked.
                if !styles.contains(where: { $0.fontName == content.fontName }) {
                    Text(content.fontName).tag(content.fontName)
                }
                ForEach(styles) { Text($0.name).tag($0.fontName) }
            }
        }
    }

    private func setFont(_ name: String) {
        onEdit { $0.text = TextContent(string: $0.text?.string ?? "", fontName: name) }
    }

    /// A row with `name` where the control rows have theirs, and a picker.
    private func labelled(_ name: String, @ViewBuilder picker: () -> some View) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 18, height: 1)
            Text(name)
                .foregroundStyle(Design.textSecondary)
                .frame(width: InspectorControlRow.nameWidth, alignment: .leading)
            picker()
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 150, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(Design.Typeface.label)
    }
}
