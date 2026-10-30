import AppKit

/// Selects the whole value when a one-line field starts being edited,
/// however it starts: a click on a field, a click on a value or name that
/// opens a field for it (`NumericField`, `InlineNameField`, a section or
/// layer being renamed), Tab, or a menu item. Typing then replaces the
/// value, as renaming a file in the Finder does, instead of adding to it
/// wherever the click left the caret. A field can also be still being
/// edited when it's clicked: put there when its sheet or panel opened, by
/// Tab, or left so by a click on something that doesn't take focus. The
/// first click on it selects its whole value too. Once a field has been
/// clicked, more clicks in it place the caret as usual, and a drag that
/// starts the edit, or across a field clicked, keeps what it selected.
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
        /// The field the last click in the window landed in, if any: a
        /// click in the field being edited places the caret only after
        /// one.
        weak var clicked: NSTextField?
    }

    private static var watches: [ObjectIdentifier: Watch] = [:]
    private static var notificationObservers: [Any] = []
    private static var clickMonitor: Any?

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
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { mouseDown(event) }
                return event
            }
        }
    }

    static func unwatch(_ window: NSWindow) {
        watches.removeValue(forKey: ObjectIdentifier(window))?.observation?.invalidate()
    }

    private static func responderChanged(in window: NSWindow) {
        guard let watch = watches[ObjectIdentifier(window)] else { return }
        let field = editedField(in: window)
        defer { watch.field = field }
        guard let field, field !== watch.field else { return }
        // A click that starts the edit, on the field or on a value that
        // opens it, is the field's first click.
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type), event.window === window,
           field.convert(field.bounds, to: nil).contains(event.locationInWindow) {
            watch.clicked = field
        }
        selectAllAfterTracking(of: field, in: window)
    }

    /// Before the window handles a click: a click in the field being
    /// edited that is its first selects its whole value.
    static func mouseDown(_ event: NSEvent) {
        guard let window = event.window, let watch = watches[ObjectIdentifier(window)] else { return }
        let field = window.contentView?.hitTest(event.locationInWindow).flatMap(textField(containing:))
        defer { watch.clicked = field }
        guard let field, field !== watch.clicked, editedField(in: window) === field else { return }
        selectAllAfterTracking(of: field, in: window)
    }

    private static func selectAllAfterTracking(of field: NSTextField, in window: NSWindow) {
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
        return textField(containing: editor)
    }

    /// The editable field `view` is, or is inside.
    private static func textField(containing view: NSView) -> NSTextField? {
        var view: NSView? = view
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
