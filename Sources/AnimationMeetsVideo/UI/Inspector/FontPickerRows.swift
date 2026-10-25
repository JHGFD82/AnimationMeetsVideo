import SwiftUI

/// A font's Font (family) and Style pickers, in the inspector's row layout,
/// for a Text effect's block or its selected letters. Changing the family
/// keeps the style's name where the new family has it (`FontCatalog`).
struct FontPickerRows: View {
    /// The PostScript name of the font shown.
    let fontName: String
    let onPick: (String) -> Void

    /// Read once: listing the Mac's fonts takes a moment.
    private static let families = FontCatalog.families()

    var body: some View {
        let shown = FontCatalog.familyAndStyle(of: fontName)
        let styles = FontCatalog.styles(ofFamily: shown.family)
        InspectorLabelledRow("Font") {
            Picker("Font", selection: Binding(
                get: { shown.family },
                set: { family in
                    guard let name = FontCatalog.fontName(inFamily: family, like: fontName) else { return }
                    onPick(name)
                }
            )) {
                ForEach(Self.families, id: \.self) { Text($0).tag($0) }
            }
        }
        InspectorLabelledRow("Style") {
            Picker("Style", selection: Binding(get: { fontName }, set: onPick)) {
                // A missing font is kept, under its own name, until another
                // is picked.
                if !styles.contains(where: { $0.fontName == fontName }) {
                    Text(fontName).tag(fontName)
                }
                ForEach(styles) { Text($0.name).tag($0.fontName) }
            }
        }
    }
}

/// A row with `name` where the control rows have theirs (after the
/// stopwatch's place), and a control, as a menu picker is laid out.
struct InspectorLabelledRow<Control: View>: View {
    let name: String
    @ViewBuilder let control: () -> Control

    init(_ name: String, @ViewBuilder control: @escaping () -> Control) {
        self.name = name
        self.control = control
    }

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 18, height: 1)
            Text(name)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(1)
                .frame(width: InspectorControlRow.nameWidth, alignment: .leading)
            control()
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 150, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(Design.Typeface.label)
    }
}
