import AppKit
import SwiftUI

/// The project's undo history, for views that make a gesture of many small
/// edits (dragging a value) and want it to be one step.
private struct ProjectHistoryKey: EnvironmentKey {
    static let defaultValue: ProjectHistory? = nil
}

extension EnvironmentValues {
    var projectHistory: ProjectHistory? {
        get { self[ProjectHistoryKey.self] }
        set { self[ProjectHistoryKey.self] = newValue }
    }
}

/// How far a value moves for each point the pointer is dragged: its unit
/// step, ten times that with Shift, a tenth with Option.
enum ValueDrag {
    static func multiplier(for flags: NSEvent.ModifierFlags) -> Double {
        if flags.contains(.shift) { return 10 }
        if flags.contains(.option) { return 0.1 }
        return 1
    }

    /// The value after the pointer has moved `distance` points from where
    /// the drag began, limited to `range`.
    static func value(from start: Double, distance: Double, step: Double, flags: NSEvent.ModifierFlags, range: ClosedRange<Double>?) -> Double {
        let moved = start + distance * step * multiplier(for: flags)
        guard let range else { return moved }
        return min(max(moved, range.lowerBound), range.upperBound)
    }
}

/// Whether the mouse press a field's drag gesture follows may start a value
/// drag. Escape ends a drag at once, but the button is still down and the
/// gesture goes on reporting moves: without this, the next move began a new
/// drag from the restored value, which went on working and left something to
/// undo. After Escape the press is ignored until the button is released.
struct ValueDragPress {
    private(set) var isCancelled = false

    var mayBegin: Bool { !isCancelled }

    /// Escape cancelled the drag.
    mutating func cancel() { isCancelled = true }

    /// The button was released.
    mutating func release() { isCancelled = false }
}

/// Drags a number: the pointer is hidden and held where the drag began, so
/// a drag can go on past the edge of the screen, and reappears there when
/// it ends. Moves are read from the mouse events' deltas. Escape ends the
/// drag and asks for the original value back.
@MainActor
final class ValueDragSession {
    private let onMove: (_ dx: Double, _ flags: NSEvent.ModifierFlags) -> Void
    private let onFinish: (_ cancelled: Bool) -> Void
    private var monitor: Any?
    private var start: CGPoint?
    private var distance = 0.0
    private var finished = false

    init(onMove: @escaping (Double, NSEvent.ModifierFlags) -> Void, onFinish: @escaping (Bool) -> Void) {
        self.onMove = onMove
        self.onFinish = onFinish
        begin()
    }

    private func begin() {
        start = CGEvent(source: nil)?.location
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDragged:
            distance += Double(event.deltaX)
            onMove(distance, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            // Taken here: passed on, every move would be hit-tested through
            // the whole window and run its gestures, for nothing, since the
            // pointer is held still. The mouse-up still goes on, ending the
            // field's own gesture.
            return true
        case .leftMouseUp:
            finish(cancelled: false)
            return false
        case .keyDown where event.keyCode == 53:
            finish(cancelled: true)
            return true
        default:
            return false
        }
    }

    /// Ends the drag. Safe to call again.
    func finish(cancelled: Bool) {
        guard !finished else { return }
        finished = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        if let start { CGWarpMouseCursorPosition(start) }
        NSCursor.unhide()
        onFinish(cancelled)
    }
}
