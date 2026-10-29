import AppKit

/// Selects the whole value when a one-line field starts being edited,
/// however it starts: a click on a field, a click on a value or name that
/// opens a field for it (`NumericField`, `InlineNameField`, a section or
/// layer being renamed), Tab, or a menu item. Typing then replaces the
/// value, as renaming a file in the Finder does, instead of adding to it
/// wherever the click left the caret. Once a field is being edited, clicks
/// in it place the caret as usual, and a drag that starts the edit keeps
/// what it selected.
///
/// One observer of each window's first responder, installed at launch
/// (`install`), covers every field in the app, so a new one needn't ask
/// for it. Text views of several lines (a text layer's words, notes) are
/// left alone: they aren't field editors.
@MainActor
enum FieldTextSelection {
    /// A window's observer, and the field being edited in it, to tell a
    /// field starting to be edited from focus moving within it.
    private final class Watch {
        var observation: NSKeyValueObservation?
        weak var field: NSTextField?
    }

    private static var watches: [ObjectIdentifier: Watch] = [:]
    private static var notificationObservers: [Any] = []

    /// Watches every window that becomes key from now on. A field can only
    /// be edited in the key window.
    static func install() {
        guard notificationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { if let window { watch(window) } }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { if let window { unwatch(window) } }
            },
        ]
        NSApp.keyWindow.map(watch)
    }

    static func watch(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard watches[id] == nil else { return }
        let watch = Watch()
        watch.field = editedField(in: window)
        // A click on a field makes the field first responder, then its
        // field editor: one change for each.
        watch.observation = window.observe(\.firstResponder) { window, _ in
            MainActor.assumeIsolated { responderChanged(in: window) }
        }
        watches[id] = watch
    }

    static func unwatch(_ window: NSWindow) {
        watches.removeValue(forKey: ObjectIdentifier(window))?.observation?.invalidate()
    }

    private static func responderChanged(in window: NSWindow) {
        guard let watch = watches[ObjectIdentifier(window)] else { return }
        let field = editedField(in: window)
        defer { watch.field = field }
        guard let field, field !== watch.field else { return }
        // In the default mode only, so after a click's tracking of the
        // mouse (which runs in the event tracking mode) has put the caret
        // where it was clicked, and after SwiftUI has given a field just
        // opened its text.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { selectAll(of: field, in: window) }
        }
    }

    /// The field whose text is being edited in `window`, if any: the one
    /// its field editor is placed in. SwiftUI's field editor has no
    /// delegate to ask.
    private static func editedField(in window: NSWindow) -> NSTextField? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        var view = editor.superview
        while let current = view {
            if let field = current as? NSTextField { return field.isEditable ? field : nil }
            view = current.superview
        }
        return nil
    }

    private static func selectAll(of field: NSTextField, in window: NSWindow) {
        guard editedField(in: window) === field, let editor = window.firstResponder as? NSTextView,
              // A drag that started the edit selected what it wanted.
              editor.selectedRange().length == 0 else { return }
        editor.selectAll(nil)
    }
}
