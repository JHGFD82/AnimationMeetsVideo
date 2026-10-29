import AppKit
import SwiftUI

/// A view in a real, key window, driven by mouse and key events sent
/// through the app as the system would, so gestures, event monitors and
/// Escape behave as they do in the editor. Opening a key window takes
/// the focus, so tests using it run only with `UI_EVENTS` set:
/// `UI_EVENTS=1 swift test --filter <suite>`.
@MainActor
final class EventHarness {
    nonisolated static var isEnabled: Bool { ProcessInfo.processInfo.environment["UI_EVENTS"] != nil }

    let window: NSWindow

    init(_ view: some View, size: CGSize) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        window.setFrameOrigin(CGPoint(x: 200, y: 200))
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
    }

    deinit {
        MainActor.assumeIsolated { window.orderOut(nil) }
    }

    /// Sends a mouse event at `point`, in the view's top-left coordinates.
    func mouse(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = []) {
        let location = CGPoint(x: point.x, y: window.frame.height - point.y)
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        NSApp.sendEvent(event)
    }

    func key(code: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        ) else { return }
        NSApp.sendEvent(event)
    }

    func escape() { key(code: 53, characters: "\u{1b}") }

    /// Lets the main actor run: SwiftUI handles events and updates in turns.
    func settle(_ milliseconds: Int = 60) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    func click(at point: CGPoint) async throws {
        mouse(.leftMouseDown, at: point)
        try await settle()
        mouse(.leftMouseUp, at: point)
        try await settle(250)
    }

    /// Presses at `from` and drags to `to` in `steps`, leaving the button
    /// down.
    func press(at from: CGPoint, dragTo to: CGPoint, steps: Int = 8) async throws {
        mouse(.leftMouseDown, at: from)
        try await settle()
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            try await settle(30)
        }
    }
}
