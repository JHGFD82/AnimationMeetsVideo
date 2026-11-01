import AppKit
import SwiftUI

/// A name edited in place, as in the Finder: shown as text, and while
/// `isEditing` as a bordered field over it, so it is plain that typing
/// renames, which commits on Return, on a click elsewhere or when it loses
/// focus, and puts the name back on Escape. An empty name, or the same
/// one, changes nothing.
///
/// The field is laid over the name rather than in its place, so nothing
/// beside it (an icon, a badge) moves when editing starts; it reaches
/// further right than a short name, for typing a longer one.
///
/// With `isSelected` given, a click on the name of an item already
/// selected starts editing once the double-click time has passed, as the
/// Finder does: not the click that selects it, nor the first of a
/// double-click, which opens it. The caller styles the text and offers
/// the other ways in (a menu item, Return).
struct InlineNameField: View {
    let name: String
    @Binding var isEditing: Bool
    /// Whether the item is selected, for click to rename; nil leaves it
    /// to the caller to start editing.
    var isSelected: Bool?
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool
    /// When the item was last selected, and the last click on the name,
    /// to tell a slow second click from the one that selected it and
    /// from a double-click.
    @State private var selectedAt = Date.distantPast
    @State private var lastClick = Date.distantPast
    @State private var pendingEdit: Task<Void, Never>?

    var body: some View {
        Text(name)
            .lineLimit(1)
            .opacity(isEditing ? 0 : 1)
            .overlay(alignment: .leading) {
                if isEditing { field }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { clicked() })
            .onChange(of: isSelected, initial: true) { _, selected in
                if selected == true { selectedAt = Date() }
                if selected != true { cancelPending() }
            }
            .onChange(of: isEditing) { _, editing in
                if editing { cancelPending() }
            }
            .onDisappear(perform: cancelPending)
    }

    private var field: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .labelsHidden()
            .focused($focused)
            // Just outside the name, so the text stays where it was.
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Design.Surface.well.color, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Design.accent, lineWidth: 1.5)
            }
            // A click on a view that doesn't take focus ends the edit too.
            .background(OutsideClickMonitor(onOutsideClick: commit))
            .padding(.horizontal, -3)
            .padding(.vertical, -1)
            .frame(minWidth: 140, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onSubmit(commit)
            .onExitCommand { isEditing = false }
            .onChange(of: focused) { _, focused in
                if !focused { commit() }
            }
            .onAppear {
                draft = name
                focused = true
            }
    }

    /// A click on the name: a slow second click on a selected item edits
    /// it, after the double-click time, unless a second click makes it a
    /// double-click first.
    private func clicked() {
        let now = Date()
        let interval = NSEvent.doubleClickInterval
        defer { lastClick = now }
        guard !isEditing, isSelected == true else { return }
        if now.timeIntervalSince(lastClick) < interval {
            // The second click of a double-click: it opens, not renames.
            cancelPending()
            return
        }
        guard now.timeIntervalSince(selectedAt) > interval else { return }
        cancelPending()
        pendingEdit = Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, isSelected == true else { return }
            isEditing = true
        }
    }

    private func cancelPending() {
        pendingEdit?.cancel()
        pendingEdit = nil
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != name else { return }
        // On the next turn of the run loop, not now: this runs while AppKit
        // ends the editing (Return, focus moving away, the row going), which
        // in a List is inside its table view's own callbacks. The new name
        // can move the row (sorted by name), and the table reordering then
        // is the reentrant operation AppKit warns about.
        DispatchQueue.main.async { onCommit(trimmed) }
    }
}
