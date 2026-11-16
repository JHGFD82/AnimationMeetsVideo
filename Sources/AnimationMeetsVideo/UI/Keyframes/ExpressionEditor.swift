import SwiftUI

/// An Expression's code in the Keyframe Designer (see
/// docs/python-scripting.md, "An expression"): ordinary Python whose last
/// line is the control's value. Edits are a draft, marked as edited, until
/// Command-Return or Apply, which also allows the code on this Mac, since
/// typing it is allowing it; Escape puts the applied code back. A mistake
/// shows under it with its line. Code that came from somewhere else is
/// shown read-only, to be allowed first.
struct ExpressionEditor: View {
    /// The code applied, as the project has it.
    let code: String
    /// Its error, from its last run: "Line 2: NameError: …".
    let failure: String?
    let approval: CodeApproval
    /// How many of the project's expressions aren't allowed, for Allow All.
    let notAllowedCount: Int
    let onApply: (String) -> Void
    let onAllowAll: () -> Void

    @State private var draft: String?
    @FocusState private var focused: Bool

    private var isAllowed: Bool { approval.allowedHashes.contains(CodeApproval.hash(of: code)) }
    private var text: String { draft ?? code }
    private var isEdited: Bool { draft.map { $0 != code } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            if isAllowed {
                editor
            } else {
                notAllowed
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    // To copy whole, as a report needs it.
                    .textSelection(.enabled)
                    .accessibilityLabel("Error: \(failure)")
            }
        }
        .onChange(of: failure) { _, failure in
            if let failure { AccessibilityNotification.Announcement("Expression has an error. \(failure)").post() }
        }
        .onChange(of: code) { _, _ in draft = nil }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(get: { text }, set: { draft = $0 }))
                .font(Design.Typeface.numeric)
                .foregroundStyle(Design.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 90, maxHeight: 220)
                .background(Design.Surface.well.color, in: RoundedRectangle(cornerRadius: Design.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius.control)
                        .strokeBorder(isEdited ? Design.accent : Design.hairline, lineWidth: 1)
                }
                .focused($focused)
                .onExitCommand { draft = nil }
                .accessibilityLabel("Expression code")
                .accessibilityValue(failure.map { "\(text). Error: \($0)" } ?? text)
                .accessibilityHint("Python whose last line is the control's value. Command-Return applies it; Escape puts back the applied code.")
            HStack(spacing: Design.Space.step) {
                if isEdited {
                    Text("Edited")
                        .font(Design.Typeface.micro)
                        .foregroundStyle(Design.textSecondary)
                }
                Spacer()
                Button("Revert") { draft = nil }
                    .disabled(!isEdited)
                Button("Apply") { apply() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!isEdited)
            }
        }
    }

    private var notAllowed: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This code came from somewhere else. It plays as saved and doesn't run until you allow it here.")
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: code)
                .font(Design.Typeface.numeric)
                .foregroundStyle(Design.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Design.Surface.well.color, in: RoundedRectangle(cornerRadius: Design.Radius.control))
                .accessibilityLabel("Expression code, not allowed yet")
                .accessibilityValue(code)
            HStack {
                Spacer()
                Button("Allow All in This Project (\(notAllowedCount))", action: onAllowAll)
                    .disabled(notAllowedCount < 2)
                Button("Allow") { approval.allow(code) }
                    .accessibilityHint("Lets this expression's code run on this Mac")
            }
        }
    }

    private func apply() {
        let code = text
        // Typing it is allowing it.
        approval.allow(code)
        onApply(code)
        draft = nil
    }
}
