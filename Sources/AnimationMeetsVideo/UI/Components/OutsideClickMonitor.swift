import AppKit
import SwiftUI

/// Calls `onOutsideClick` when the mouse goes down anywhere in this view's
/// window except on it, so a field being edited takes what was typed when
/// the person clicks or starts dragging something else, even on a view
/// that doesn't take focus. The click still goes through to what was
/// clicked.
struct OutsideClickMonitor: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.pressed(event) }
                return event
            }
        }

        /// Before the window handles a press: one outside this view ends
        /// the edit.
        func pressed(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            let inside = convert(bounds, to: nil).contains(event.locationInWindow)
            if !inside { onOutsideClick?() }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
