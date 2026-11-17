import SwiftUI

/// The button at the end of a row that puts its value back where it
/// started: a control's default, or the block's own for letters that were
/// given one of theirs. Shown only while the value differs, which is how a
/// changed value is told apart. One look wherever a value can be reset,
/// with the start-over glyph, never Undo's.
struct RowResetButton: View {
    /// What the button says under the pointer.
    let help: String
    /// What VoiceOver calls it.
    let label: String
    let action: () -> Void

    /// Resets the row named `name` to its default.
    init(name: String, action: @escaping () -> Void) {
        self.help = "Reset \(name.lowercased()) to its default"
        self.label = "Reset \(name)"
        self.action = action
    }

    /// Puts a value back to something other than a default, which `help`
    /// and `label` name: "Use the block's size".
    init(help: String, label: String, action: @escaping () -> Void) {
        self.help = help
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: Design.Symbol.startOver)
                .font(Design.Typeface.glyphSmall)
                .foregroundStyle(Design.textSecondary)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}
