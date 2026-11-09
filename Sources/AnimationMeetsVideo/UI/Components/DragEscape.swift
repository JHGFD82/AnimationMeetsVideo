import AppKit

/// Escape during a drag the app follows itself, such as moving or
/// trimming a clip: while one is watched, Escape calls `onEscape` and goes
/// no further, so it cancels the drag rather than also clearing the
/// selection (see `TimelineView.handleKey`). It takes Escape once; it
/// stops when the mouse button comes up, even if the drag's own end is
/// never heard (its view went away, or the system cancelled the gesture),
/// so Escape outside a drag is always the timeline's.
///
/// A view following a SwiftUI drag gesture uses `EscapableDrag`, which
/// keeps one of these for each drag; this is for drags that keep their
/// own book, as clip blocks do (`ClipDragBook`).
@MainActor
final class DragEscape {
    /// Whether a drag is listening for Escape, which is then its own.
    static var isActive: Bool { listening > 0 }
    private static var listening = 0

    private var monitor: Any?
    /// Still taking Escape: not pressed yet, and the button still down.
    private var takesEscape = true
    private let onEscape: () -> Void
    private let onRelease: () -> Void

    /// `onRelease` is called when the mouse button comes up, before the
    /// drag's gesture hears it.
    init(onEscape: @escaping () -> Void, onRelease: @escaping () -> Void = {}) {
        self.onEscape = onEscape
        self.onRelease = onRelease
        Self.listening += 1
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let taken = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .leftMouseUp {
                    // Seen, not taken: the drag's gesture ends on it.
                    self.buttonCameUp()
                    return false
                }
                guard event.keyCode == 53 else { return false }
                return self.escapePressed()
            }
            return taken ? nil : event
        }
    }

    /// Escape was pressed: whether it was taken, which it is once.
    func escapePressed() -> Bool {
        guard takesEscape else { return false }
        stopTakingEscape()
        onEscape()
        return true
    }

    /// The mouse button came up: the drag is over.
    func buttonCameUp() {
        let wasListening = monitor != nil
        end()
        if wasListening { onRelease() }
    }

    /// Stops listening. Safe to call again.
    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        stopTakingEscape()
    }

    private func stopTakingEscape() {
        guard takesEscape else { return }
        takesEscape = false
        Self.listening -= 1
    }

    isolated deinit { end() }
}

/// A drag gesture that Escape cancels, put back as it was before the drag
/// began, the rest of the drag ignored. Kept in a view's `@State`, one for
/// all the drags of the view that can't run at once:
///
/// ```swift
/// DragGesture()
///     .onChanged { value in
///         guard escape.follow(onEscape: { putBack() }) else { return }
///         ... // follow the drag
///     }
///     .onEnded { value in
///         guard escape.end() else { return }
///         ... // commit it
///     }
/// ```
///
/// `onEscape` takes down whatever the drag shows (drafts, previews, the
/// timecode readout, auto-scrolling) and edits nothing. A drag cancelled
/// whose end is never heard (its view went away) doesn't hold up the next
/// one: the button coming up lets the next drag begin afresh.
@MainActor
final class EscapableDrag {
    private var escape: DragEscape?
    /// Escape cancelled the drag in progress.
    private(set) var isCancelled = false
    /// The button came up since the drag began, so its next move is a new
    /// drag's, whether or not this one's end was heard.
    private var released = false

    /// Whether a drag is in progress, cancelled or not.
    var isRunning: Bool { escape != nil && !released }

    /// Call on each move of the drag, before following it. The first move
    /// of a drag begins listening for Escape, which then calls `onEscape`
    /// once. False once the drag was cancelled: ignore the move.
    func follow(onEscape: @escaping () -> Void) -> Bool {
        if !isRunning {
            escape?.end()
            isCancelled = false
            released = false
            escape = DragEscape(
                onEscape: { [weak self] in
                    self?.isCancelled = true
                    onEscape()
                },
                onRelease: { [weak self] in self?.released = true }
            )
        }
        return !isCancelled
    }

    /// Call when the drag ends: whether to commit it, false when Escape
    /// cancelled it. A press that never moved (a click) isn't cancelled.
    /// Then ready for the next drag.
    @discardableResult
    func end() -> Bool {
        let commits = !isCancelled
        escape?.end()
        escape = nil
        isCancelled = false
        released = false
        return commits
    }

    /// For tests, standing in for the key and the button.
    func pressEscape() { _ = escape?.escapePressed() }
    func releaseButton() { escape?.buttonCameUp() }
}
