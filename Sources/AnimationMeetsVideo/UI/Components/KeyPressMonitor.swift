import AppKit
import SwiftUI

/// Calls `handler` for key presses in this view's window while no text is
/// being edited there, so single-letter shortcuts don't swallow typing. The
/// handler returns true when it used the key.
///
/// It also stands aside for the keys a focused view has claimed
/// (`claimsKeys`): a graph that takes the arrows and Delete with
/// `onKeyPress` only hears them if no panel's monitor took them first.
struct KeyPressMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handler = handler
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        /// Only listens for keys; clicks go to the views around it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          !(window.firstResponder is NSText),
                          !KeyClaim.isClaimed(event, in: window)
                    else {
                        return false
                    }
                    return self.handler?(event) == true
                }
                return handled ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Keys a SwiftUI view takes itself with `onKeyPress` while it has the
/// keyboard, such as a tone or EQ graph's arrows, Tab and Delete. Every
/// `KeyPressMonitor` in its window leaves those keys to it meanwhile, so
/// Delete removes the picked curve point rather than the effect or the
/// clip, and the arrows move it rather than the playhead. Keys it doesn't
/// claim, and any with Command, still reach the panels.
///
/// A focusable view keeps SwiftUI's focus after a click on something that
/// never takes focus (the timeline, the viewer), so a press anywhere
/// outside the view calls `onOutsidePress`, which should let the focus
/// go: the keys are then the panels' again, as the click suggests.
struct KeyClaim: NSViewRepresentable {
    let keys: Set<KeyEquivalent>
    let isActive: Bool
    let onOutsidePress: () -> Void

    func makeNSView(context: Context) -> ClaimView {
        let view = ClaimView()
        update(view)
        return view
    }

    func updateNSView(_ view: ClaimView, context: Context) {
        update(view)
    }

    private func update(_ view: ClaimView) {
        view.keys = keys
        view.isActive = isActive
        view.onOutsidePress = onOutsidePress
    }

    static func dismantleNSView(_ view: ClaimView, coordinator: ()) {
        view.stop()
    }

    /// Whether a view in `window` with the keyboard has claimed `event`'s
    /// key.
    @MainActor
    static func isClaimed(_ event: NSEvent, in window: NSWindow) -> Bool {
        ClaimView.all.allObjects.contains { $0.window === window && $0.claims(event) }
    }

    /// The key `event` is, as `onKeyPress` names it: the named keys by
    /// their key code, so Shift-Tab is still Tab and Delete is Delete
    /// whatever characters it types, and others by the character typed
    /// without modifiers.
    static func key(of event: NSEvent) -> KeyEquivalent? {
        switch event.keyCode {
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        case 48: return .tab
        case 51: return .delete
        case 117: return .deleteForward
        case 53: return .escape
        case 36, 76: return .return
        case 49: return .space
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        default: return event.charactersIgnoringModifiers?.first.map { KeyEquivalent($0) }
        }
    }

    /// Whether a view claiming `keys` takes `event`.
    static func claims(_ keys: Set<KeyEquivalent>, _ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.modifierFlags.contains(.command), let key = key(of: event) else { return false }
        return keys.contains(key)
    }

    final class ClaimView: NSView {
        /// Every claim on screen, for the monitors to ask.
        static let all = NSHashTable<ClaimView>.weakObjects()

        var keys: Set<KeyEquivalent> = []
        var isActive = false
        var onOutsidePress: (() -> Void)?
        private var monitor: Any?

        /// Takes no clicks; it only spans the view that claims the keys.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func claims(_ event: NSEvent) -> Bool {
            isActive && !isHiddenOrHasHiddenAncestor && KeyClaim.claims(keys, event)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            Self.all.add(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.pressed(event) }
                return event
            }
        }

        private func pressed(_ event: NSEvent) {
            guard isActive, let window, event.window === window else { return }
            if bounds.contains(convert(event.locationInWindow, from: nil)) { return }
            onOutsidePress?()
        }

        func stop() {
            Self.all.remove(self)
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

extension View {
    /// Claims `keys` from the panels' key monitors while `isFocused` (see
    /// `KeyClaim`), and lets the focus go on a press outside the view.
    func claimsKeys(_ keys: Set<KeyEquivalent>, while isFocused: FocusState<Bool>.Binding) -> some View {
        background(KeyClaim(keys: keys, isActive: isFocused.wrappedValue) { isFocused.wrappedValue = false })
    }
}
