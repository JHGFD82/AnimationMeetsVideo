import AppKit

/// The copy pointer (an arrow with a plus) for drags the app moves itself,
/// such as a clip or a layer header, while Option is held: the system
/// shows it only for drags it carries.
@MainActor
enum CopyDragCursor {
    private static var isShown = false

    /// Shows or hides the copy pointer as Option is held or let go, and
    /// says whether the drag copies.
    @discardableResult
    static func update() -> Bool {
        let copying = NSEvent.modifierFlags.contains(.option)
        if copying != isShown {
            if copying { NSCursor.dragCopy.push() } else { NSCursor.pop() }
            isShown = copying
        }
        return copying
    }

    /// The drag ended: back to the pointer it had.
    static func end() {
        if isShown { NSCursor.pop() }
        isShown = false
    }
}
