import AppKit
import SwiftUI

/// Scroll-wheel events over the view it backs, with the pointer's place in
/// that view (top-left origin, as SwiftUI's), for a drawn view that turns
/// scrolling into a change of value. It only watches: clicks go to the
/// views around it, and a scroll it doesn't take scrolls what it would
/// have.
///
/// A scroll is taken or not as a whole, by where it began
/// (`ScrollGestureClaim`): one that began scrolling the panel goes on
/// scrolling it when the view's target passes under the pointer, and its
/// momentum never becomes a change of value.
struct ScrollWheelMonitor: NSViewRepresentable {
    /// Called with the distance in points (positive when scrolling right
    /// and up, as the content then moves) and the pointer. Return true to
    /// keep the event from scrolling anything else.
    private let onScroll: (_ delta: CGVector, _ location: CGPoint) -> Bool
    /// Whether a scroll across alone is offered, rather than only the
    /// vertical part of one.
    private let bothAxes: Bool

    /// Offers the vertical distance in points (positive when scrolling
    /// up) and the pointer.
    init(onScroll: @escaping (_ deltaY: CGFloat, _ location: CGPoint) -> Bool) {
        self.onScroll = { delta, location in onScroll(delta.dy, location) }
        bothAxes = false
    }

    private init(both onScroll: @escaping (_ delta: CGVector, _ location: CGPoint) -> Bool) {
        self.onScroll = onScroll
        bothAxes = true
    }

    /// Offers the distance on both axes at once, as the viewer moves its
    /// picture: a two-finger scroll in any direction, or a mouse wheel's
    /// up and down (across with Shift, as the system has it).
    static func bothAxes(_ onScroll: @escaping (_ delta: CGVector, _ location: CGPoint) -> Bool) -> ScrollWheelMonitor {
        ScrollWheelMonitor(both: onScroll)
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        view.bothAxes = bothAxes
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onScroll = onScroll
        view.bothAxes = bothAxes
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onScroll: ((CGVector, CGPoint) -> Bool)?
        var bothAxes = false
        private var monitor: Any?
        private var claim = ScrollGestureClaim()

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor, !WindowInputBlock.isBlocked(window) else { return false }
            let point = convert(event.locationInWindow, from: nil)
            // A mouse wheel reports lines, not points.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            let deltaY = event.scrollingDeltaY * scale
            let deltaX = bothAxes ? event.scrollingDeltaX * scale : 0
            let moves = deltaY != 0 || deltaX != 0
            return claim.handle(
                phase: event.phase, momentumPhase: event.momentumPhase, moves: moves, time: event.timestamp
            ) {
                guard bounds.contains(point), moves else { return false }
                return onScroll?(CGVector(dx: deltaX, dy: deltaY), point) ?? false
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Whether a scroll is a view's own, decided once per scroll by its first
/// event that moves: a trackpad's from when the fingers touch, a mouse
/// wheel's by the first click of a run (clicks less than `wheelPause`
/// apart are one scroll). The rest of the scroll follows that decision, so
/// a scroll that began elsewhere never turns into the view's when what it
/// acts on comes under the pointer, and momentum after the fingers lift is
/// never the view's: it is swallowed after a scroll the view took, so the
/// panel doesn't coast on, and passed on otherwise.
struct ScrollGestureClaim {
    /// Clicks of a mouse wheel closer than this are one scroll.
    static let wheelPause: TimeInterval = 0.3

    /// Whether the scroll under way is the view's; nil until it is known.
    private var isTaken: Bool?
    private var lastWheel: TimeInterval?

    /// Handles one scroll event, which `moves` when it has a distance:
    /// `take` offers it to the view, which returns whether it used it, and
    /// is only called while the view may have the scroll. Returns whether
    /// the event was used up.
    mutating func handle(
        phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, moves: Bool, time: TimeInterval, take: () -> Bool
    ) -> Bool {
        if !momentumPhase.isEmpty {
            let taken = isTaken == true
            if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) { isTaken = nil }
            return taken
        }
        if phase.isEmpty {
            // A mouse wheel, which has no phases: a pause starts a new
            // scroll.
            if lastWheel.map({ time - $0 >= Self.wheelPause }) ?? true { isTaken = nil }
            lastWheel = time
        } else if phase.contains(.began) || phase.contains(.mayBegin) {
            isTaken = nil
        }
        if let isTaken {
            if isTaken { _ = take() }
            return isTaken
        }
        guard moves else { return false }
        let taken = take()
        isTaken = taken
        return taken
    }
}
