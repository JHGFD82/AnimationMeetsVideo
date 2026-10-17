import AppKit
import SwiftUI

/// Which way a pinch zooms: across (time) or up and down (layer height).
enum PinchAxis {
    case horizontal, vertical
}

/// Pinch and scroll-wheel events over the view it backs, with the pointer's
/// x in that view, so the timeline can zoom about the pointer and scroll
/// itself sideways. Vertical scrolling is left for the scroll views of the
/// areas.
///
/// A pinch zooms along the line between the two fingers as they land:
/// side by side zooms time, one above the other zooms layer height. The
/// axis is fixed for the rest of that pinch, so a pinch that drifts doesn't
/// flip between the two. Without finger positions (some input devices
/// don't report them) a pinch zooms time, or layer height with Shift.
/// Option-pinch always zooms layer height, whatever the fingers do.
struct TimelineInputMonitor: NSViewRepresentable {
    /// Called with the factor to scale by, the axis, the pointer's x in
    /// this view and the pointer in window coordinates (top-left origin,
    /// as SwiftUI's global space).
    let onMagnify: (CGFloat, PinchAxis, CGFloat, CGPoint) -> Void
    /// Called with a sideways distance in points (positive scrolls later in
    /// time). Return true to keep the event from scrolling anything else.
    let onScroll: (_ deltaX: CGFloat, _ deltaY: CGFloat, _ flags: NSEvent.ModifierFlags, _ x: CGFloat) -> Bool
    /// Called when the fingers of a pinch lift.
    var onMagnifyEnded: () -> Void = {}

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onMagnify = onMagnify
        view.onScroll = onScroll
        view.onMagnifyEnded = onMagnifyEnded
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onMagnify = onMagnify
        view.onScroll = onScroll
        view.onMagnifyEnded = onMagnifyEnded
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onMagnify: ((CGFloat, PinchAxis, CGFloat, CGPoint) -> Void)?
        var onScroll: ((CGFloat, CGFloat, NSEvent.ModifierFlags, CGFloat) -> Bool)?
        var onMagnifyEnded: (() -> Void)?
        private var monitor: Any?
        /// The axis of the pinch in progress, fixed once its fingers are seen.
        private var pinchAxis: PinchAxis?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // Gesture events then carry the fingers on the trackpad.
            allowedTouchTypes = [.indirect]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

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
                if event.phase == .began || event.phase == .mayBegin { pinchAxis = nil }
                let axis = pinchAxis ?? axis(of: event)
                if pinchAxis == nil, fingerSpread(of: event) != nil { pinchAxis = axis }
                if event.phase == .ended || event.phase == .cancelled { pinchAxis = nil }
                let height = window.contentView?.bounds.height ?? 0
                let global = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
                onMagnify?(1 + event.magnification, axis, point.x, global)
                if event.phase == .ended || event.phase == .cancelled { onMagnifyEnded?() }
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

        /// Option always zooms layer height. Otherwise the axis a pinch's
        /// fingers lie along, or by Shift without them.
        private func axis(of event: NSEvent) -> PinchAxis {
            if event.modifierFlags.contains(.option) { return .vertical }
            if let spread = fingerSpread(of: event) {
                return abs(spread.width) >= abs(spread.height) ? .horizontal : .vertical
            }
            return event.modifierFlags.contains(.shift) ? .vertical : .horizontal
        }

        /// The distance between the first two fingers on the trackpad, in
        /// points of the trackpad's own surface; nil without two fingers.
        private func fingerSpread(of event: NSEvent) -> CGSize? {
            let touches = Array(event.touches(matching: .touching, in: self))
            guard touches.count >= 2 else { return nil }
            let size = touches[0].deviceSize
            let a = touches[0].normalizedPosition, b = touches[1].normalizedPosition
            return CGSize(width: (a.x - b.x) * size.width, height: (a.y - b.y) * size.height)
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
