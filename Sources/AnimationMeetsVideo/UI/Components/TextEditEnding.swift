import AppKit

/// Ends the text being edited in a window when the mouse goes down
/// anywhere else in it, before the window handles the press, so what was
/// typed is taken and the keys go back to the app. A click on the timeline,
/// the viewer, a waveform or a graph moves nothing by itself, since those
/// views never take focus: without this, a field or a text layer's words
/// kept the keyboard, and Space, Delete and the arrows edited the text
/// instead of the timeline.
///
/// Editing ends by making the window its own first responder. Each field
/// already commits when it loses focus (`NumericField`, `InlineNameField`,
/// a layer, section or effect being renamed, a sheet's fields), and a text
/// view keeps its selection, so the letters picked for Character stay
/// picked. The press still goes on to what was clicked.
///
/// One monitor, installed at launch (`install`), covers every window and
/// every field, so a new one needn't ask for it.
@MainActor
enum TextEditEnding {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { pressed(event) }
            return event
        }
    }

    /// Before the window handles a press: one outside the text being
    /// edited ends the edit. A window under a sheet takes no clicks
    /// (`WindowInputBlock`), so its edit stays.
    static func pressed(_ event: NSEvent) {
        guard let window = event.window, !WindowInputBlock.isBlocked(window),
              let editing = editedView(in: window) else { return }
        // Hit-tested, not compared with frames: SwiftUI's AppKit views can
        // span more than they draw.
        if let hit = window.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: editing) { return }
        window.makeFirstResponder(nil)
    }

    /// What a click must land in to keep the edit: the field a field
    /// editor is placed in, or a text view with its scroll view (and so its
    /// scroller). Nil when no text is being edited.
    static func editedView(in window: NSWindow) -> NSView? {
        guard let text = window.firstResponder as? NSTextView else { return nil }
        if text.isFieldEditor {
            var view: NSView? = text
            while let current = view {
                if current is NSTextField { return current }
                view = current.superview
            }
            return text
        }
        return text.enclosingScrollView ?? text
    }
}
