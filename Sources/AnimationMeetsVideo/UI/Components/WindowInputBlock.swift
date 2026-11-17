import AppKit

/// Keeps the pointer out of a window while a draft panel works over it, as
/// Beat Match and the motion designer do: the window is dimmed and takes
/// no clicks, drags or hovering until the panel closes. SwiftUI's
/// `disabled` stops clicks on controls but not hovering, so skimming and
/// hover highlights went on under the dim; this takes those pointer
/// events aimed at the window before the window sees it. A click on it
/// calls `onClick` instead, to bring the panel back.
///
/// Scrolling and pinching still reach a window under a draft panel
/// (`lookingEvents`), so the person can look along the timeline while the
/// panel is open: they move and zoom views and change nothing. Views that
/// turn a scroll into a change of value (`ScrollWheelMonitor`) still ask
/// `isBlocked` and take none.
///
/// A window with a sheet attached (a dialog such as New Timeline, or an
/// alert, which darken it) is kept from the pointer the same way, by one
/// monitor installed at launch (`blockUnderSheets`): AppKit stops clicks
/// on its controls, but not hovering, so skimming went on under the
/// dialog, and the local monitors still saw its clicks.
///
/// Other local monitors may run before this one, so those that act on the
/// pointer (`TimelineInputMonitor` and the like) also ask `isBlocked`.
@MainActor
final class WindowInputBlock {
    private static var blocked: Set<ObjectIdentifier> = []
    private static var sheetMonitor: Any?

    /// Whether pointer events aimed at `window` are being kept from it:
    /// while a draft panel works over it, or a sheet is attached to it.
    /// Scrolling and pinching may still reach it (see `blocks`).
    static func isBlocked(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return blocked.contains(ObjectIdentifier(window)) || window.attachedSheet != nil
    }

    /// Pointer events that only look around: scrolling and pinching,
    /// which move and zoom views without changing anything. A draft panel
    /// lets them through to the window it works over; a sheet doesn't.
    static let lookingEvents: NSEvent.EventTypeMask = [.scrollWheel, .magnify, .smartMagnify]

    /// Whether `event`, aimed at `window`, is kept from it: every pointer
    /// event under a sheet, and all but `lookingEvents` under a draft
    /// panel. For monitors that only move or zoom a view.
    static func blocks(_ event: NSEvent, in window: NSWindow?) -> Bool {
        blocks(event.type, in: window)
    }

    static func blocks(_ type: NSEvent.EventType, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window.attachedSheet != nil { return true }
        guard blocked.contains(ObjectIdentifier(window)) else { return false }
        return !lookingEvents.contains(NSEvent.EventTypeMask(type: type))
    }

    /// Keeps the pointer out of any window while a sheet is attached to
    /// it. The sheet's own events are aimed at the sheet, so they go on.
    static func blockUnderSheets() {
        guard sheetMonitor == nil else { return }
        sheetMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { event in
            nonisolated(unsafe) let event = event
            let taken = MainActor.assumeIsolated { event.window?.attachedSheet != nil }
            return taken ? nil : event
        }
    }

    private weak var window: NSWindow?
    private var monitor: Any?

    private static let pointerEvents: NSEvent.EventTypeMask = [
        .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate,
        .leftMouseDown, .leftMouseDragged, .leftMouseUp,
        .rightMouseDown, .rightMouseDragged, .rightMouseUp,
        .otherMouseDown, .otherMouseDragged, .otherMouseUp,
        .scrollWheel, .magnify, .smartMagnify, .rotate, .swipe, .pressure,
    ]

    init(window: NSWindow?, onClick: @escaping () -> Void) {
        guard let window else { return }
        self.window = window
        Self.blocked.insert(ObjectIdentifier(window))
        monitor = NSEvent.addLocalMonitorForEvents(matching: Self.pointerEvents) { [weak window] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let window, event.window === window, Self.blocks(event, in: window) else { return false }
                if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { onClick() }
                return true
            }
            return taken ? nil : event
        }
        // Whatever the pointer was doing over the window stops with it.
        NSCursor.arrow.set()
    }

    /// Gives the window its pointer back.
    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let window { Self.blocked.remove(ObjectIdentifier(window)) }
        window = nil
    }
}
