import AppKit

/// Escape during a drag the app follows itself, such as moving or
/// trimming a clip: while one is watched, Escape calls `onEscape` and goes
/// no further, so it cancels the drag rather than also clearing the
/// selection (see `TimelineView.handleKey`). It stops when the mouse
/// button comes up, even if the drag's own end is never heard (its view
/// went away, or the system cancelled the gesture), so Escape outside a
/// drag is always the timeline's.
@MainActor
final class DragEscape {
    /// Whether a drag is listening for Escape, which is then its own.
    private(set) static var isActive = false

    private var monitor: Any?
    private let onEscape: () -> Void

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
        Self.isActive = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let taken = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .leftMouseUp {
                    // Seen, not taken: the drag's gesture ends on it.
                    self.end()
                    return false
                }
                guard event.keyCode == 53 else { return false }
                self.onEscape()
                return true
            }
            return taken ? nil : event
        }
    }

    /// Stops listening. Safe to call again.
    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if monitor != nil { Self.isActive = false }
        monitor = nil
    }

    isolated deinit { end() }
}
