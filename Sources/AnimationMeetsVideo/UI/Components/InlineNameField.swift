import SwiftUI

/// A name edited in place: shown as text, and while `isEditing` as a
/// field holding it, which commits on Return or when it loses focus and
/// puts the name back on Escape. An empty name, or the same one, changes
/// nothing. The caller styles the text and says what starts the editing.
struct InlineNameField: View {
    let name: String
    @Binding var isEditing: Bool
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { isEditing = false }
                .onChange(of: focused) { _, focused in
                    if !focused { commit() }
                }
                .onAppear {
                    draft = name
                    focused = true
                }
        } else {
            Text(name)
                .lineLimit(1)
        }
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != name { onCommit(trimmed) }
    }
}
