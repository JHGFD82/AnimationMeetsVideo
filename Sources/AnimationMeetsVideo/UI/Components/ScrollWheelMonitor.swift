import AppKit
import SwiftUI

/// Scroll-wheel events over the view it backs, with the pointer's place in
/// that view (top-left origin, as SwiftUI's), for a drawn view that turns
/// scrolling into a change of value. It only watches: clicks go to the
/// views around it, and a scroll it doesn't take scrolls what it would
/// have.
struct ScrollWheelMonitor: NSViewRepresentable {
    /// Called with the vertical distance in points (positive when
    /// scrolling up) and the pointer. Return true to keep the event from
    /// scrolling anything else.
    let onScroll: (_ deltaY: CGFloat, _ location: CGPoint) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onScroll: ((CGFloat, CGPoint) -> Bool)?
        private var monitor: Any?

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
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), event.scrollingDeltaY != 0 else { return false }
            // A mouse wheel reports lines, not points.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            return onScroll?(event.scrollingDeltaY * scale, point) ?? false
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
