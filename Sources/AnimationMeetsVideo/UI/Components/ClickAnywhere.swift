import AppKit
import SwiftUI

extension View {
    /// Runs `action` on the next click of any button anywhere in the
    /// view's window, while `isActive`. The click still goes where it was
    /// aimed: this only listens, for things like a notice that any click
    /// puts away.
    func onClickAnywhere(isActive: Bool, perform action: @escaping () -> Void) -> some View {
        background(ClickAnywhereMonitor(isActive: isActive, action: action))
    }
}

private struct ClickAnywhereMonitor: NSViewRepresentable {
    let isActive: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.action = action
        view.isActive = isActive
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.isActive = false
    }

    final class MonitorView: NSView {
        var action: () -> Void = {}
        var isActive = false {
            didSet { if isActive != oldValue { isActive ? startMonitoring() : stopMonitoring() } }
        }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func startMonitoring() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated {
                    if let self, event.window === self.window { self.action() }
                }
                return event
            }
        }

        private func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
