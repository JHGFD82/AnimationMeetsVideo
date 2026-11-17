import AppKit
import SwiftUI

/// Calls `onDown` and `onUp` as one key goes down and comes up in this
/// view's window, its repeats dropped, while `isActive` and no text is
/// being edited there (as `KeyPressMonitor` stands aside). `onDown` returns
/// whether it took the key, which then goes no further: a local monitor
/// hears it before the window's shortcuts do, so Space held for the pen's
/// hand never reaches the play button's `.keyboardShortcut(.space)`.
///
/// A control with the keyboard (a button or picker reached with Tab) keeps
/// the key: Space presses it, as it always does.
///
/// If the window stops being the key window while the key is down,
/// `onUp` is called then, since the key's release would never arrive.
struct KeyHoldMonitor: NSViewRepresentable {
    /// The key's code: 49 for Space.
    let keyCode: UInt16
    var isActive = true
    let onDown: () -> Bool
    let onUp: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        update(view)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        update(view)
    }

    private func update(_ view: MonitorView) {
        view.keyCode = keyCode
        view.isActive = isActive
        view.onDown = onDown
        view.onUp = onUp
        if !isActive { view.release() }
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var keyCode: UInt16 = 49
        var isActive = true
        var onDown: (() -> Bool)?
        var onUp: (() -> Void)?
        /// Whether the key went down here and hasn't come up.
        private(set) var isDown = false
        private var monitor: Any?
        private var resign: NSObjectProtocol?

        /// Only listens for keys; clicks go to the views around it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let taken = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return taken ? nil : event
            }
            resign = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.release() }
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, event.keyCode == keyCode else { return false }
            switch event.type {
            case .keyDown:
                guard isActive, !(window.firstResponder is NSText), !(window.firstResponder is NSControl) else { return false }
                // Command or Control with the key is someone else's.
                guard event.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
                if event.isARepeat { return isDown }
                guard !isDown else { return true }
                guard onDown?() == true else { return false }
                isDown = true
                return true
            case .keyUp:
                guard isDown else { return false }
                release()
                return true
            default:
                return false
            }
        }

        /// The key is up, or can no longer be heard coming up.
        func release() {
            guard isDown else { return }
            isDown = false
            onUp?()
        }

        func stopMonitoring() {
            release()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let resign { NotificationCenter.default.removeObserver(resign) }
            resign = nil
        }
    }
}
