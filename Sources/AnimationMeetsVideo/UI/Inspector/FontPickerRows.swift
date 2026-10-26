import SwiftUI

/// A font's family and style menus, full width one above the other as in
/// Illustrator's Character panel, for a Text effect's block or its
/// selected letters. Changing the family keeps the style's name where the
/// new family has it (`FontCatalog`).
struct FontPickerRows: View {
    /// The PostScript name of the font shown.
    let fontName: String
    let onPick: (String) -> Void

    /// Read once: listing the Mac's fonts takes a moment.
    private static let families = FontCatalog.families()

    var body: some View {
        let shown = FontCatalog.familyAndStyle(of: fontName)
        var styles = FontCatalog.styles(ofFamily: shown.family).map { (value: $0.fontName, name: $0.name) }
        // A missing font is kept, under its own name, until another is
        // picked.
        if !styles.contains(where: { $0.value == fontName }) {
            styles.insert((fontName, fontName), at: 0)
        }
        return VStack(spacing: Design.Space.close) {
            PanelMenuField(
                glyph: .symbol("textformat"), name: "Font", options: Self.families.map { ($0, $0) }, selection: shown.family
            ) { family in
                guard let name = FontCatalog.fontName(inFamily: family, like: fontName) else { return }
                onPick(name)
            }
            PanelMenuField(glyph: .symbol("bold.italic.underline"), name: "Font Style", options: styles, selection: fontName, onPick: onPick)
        }
    }
}

/// A row with `name` where the control rows have theirs, and a control
/// filling the rest.
struct InspectorLabelledRow<Control: View>: View {
    let name: String
    @ViewBuilder let control: () -> Control

    init(_ name: String, @ViewBuilder control: @escaping () -> Control) {
        self.name = name
        self.control = control
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(1)
                .frame(width: InspectorControlRow.nameWidth, alignment: .leading)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Design.Typeface.label)
    }
}
