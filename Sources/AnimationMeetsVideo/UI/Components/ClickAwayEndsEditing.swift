import AppKit
import SwiftUI

extension View {
    /// Ends the typing in a field or text view inside this view when the
    /// mouse goes down anywhere else in the window, as Return or Tab
    /// would: what was typed is entered and the field lets go of the
    /// keyboard. The click still goes through to what was clicked.
    ///
    /// AppKit ends an edit only when the click lands on something that
    /// takes the keyboard (another field, a focusable list), so clicks on
    /// the panel's background, the viewer, the timeline or a plain button
    /// left the field being edited, keeping every key press.
    func endsEditingOnClickAway() -> some View {
        background(ClickAwayEndsEditing())
    }
}

/// See `endsEditingOnClickAway`. Its view sits behind the content it
/// covers, so it isn't an ancestor of the fields there: a field counts as
/// inside when its frame overlaps this view's.
struct ClickAwayEndsEditing: NSViewRepresentable {
    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {}

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.pressed(event) }
                return event
            }
        }

        /// Before the window handles a press: one outside the text being
        /// edited in this view ends the edit.
        func pressed(_ event: NSEvent) {
            guard let window, event.window === window, !WindowInputBlock.isBlocked(window),
                  let editing = Self.editedView(in: window),
                  convert(bounds, to: nil).intersects(editing.convert(editing.bounds, to: nil)),
                  let content = window.contentView
            else { return }
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            if let hit = content.hitTest(point), hit === editing || hit.isDescendant(of: editing) { return }
            window.makeFirstResponder(nil)
        }

        /// What is being typed in, as the pointer sees it: a one-line field
        /// (its field editor is placed inside it), or a text view with the
        /// scroll view around it, whose scroller doesn't end the edit.
        static func editedView(in window: NSWindow) -> NSView? {
            guard let editor = window.firstResponder as? NSTextView, editor.isEditable else { return nil }
            if editor.isFieldEditor {
                var view: NSView? = editor
                while let current = view {
                    if current is NSTextField { return current }
                    view = current.superview
                }
                return editor
            }
            return editor.enclosingScrollView ?? editor
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
