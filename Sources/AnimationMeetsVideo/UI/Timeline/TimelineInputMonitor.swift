import AppKit
import SwiftUI

/// Pinch and scroll-wheel events over the view it backs, with the pointer's
/// x in that view, so the timeline can zoom about the pointer and scroll
/// itself sideways. Vertical scrolling is left for the scroll view around
/// the layers.
struct TimelineInputMonitor: NSViewRepresentable {
    /// Called with the factor to scale by and the pointer's x.
    let onMagnify: (CGFloat, CGFloat) -> Void
    /// Called with a sideways distance in points (positive scrolls later in
    /// time). Return true to keep the event from scrolling anything else.
    let onScroll: (_ deltaX: CGFloat, _ deltaY: CGFloat, _ flags: NSEvent.ModifierFlags, _ x: CGFloat) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onMagnify = onMagnify
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onMagnify = onMagnify
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onMagnify: ((CGFloat, CGFloat) -> Void)?
        var onScroll: ((CGFloat, CGFloat, NSEvent.ModifierFlags, CGFloat) -> Bool)?
        private var monitor: Any?

        /// Only watches events; clicks go to the views around it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
            switch event.type {
            case .magnify:
                onMagnify?(1 + event.magnification, point.x)
                return true
            case .scrollWheel:
                // A mouse wheel reports lines, not points.
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                return onScroll?(-event.scrollingDeltaX * scale, event.scrollingDeltaY * scale, flags, point.x) ?? false
            default:
                return false
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
