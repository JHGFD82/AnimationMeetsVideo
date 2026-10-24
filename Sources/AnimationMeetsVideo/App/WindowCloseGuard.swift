import AppKit
import SwiftUI

/// Asks `shouldClose` before this view's window closes, so a question about
/// unsaved changes appears while the window is still on screen rather than
/// after it is gone. SwiftUI owns the window's delegate, so the guard sits
/// in front of it and passes every other delegate call through.
struct WindowCloseGuard: NSViewRepresentable {
    /// Given the window, so an answer of no can close it later itself.
    let shouldClose: (NSWindow) -> Bool

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.shouldClose = shouldClose
        return view
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.shouldClose = shouldClose
    }

    final class GuardView: NSView {
        var shouldClose: ((NSWindow) -> Bool)?
        private var proxy: DelegateProxy?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !(window.delegate is DelegateProxy) else { return }
            let proxy = DelegateProxy(original: window.delegate) { [weak self] window in
                self?.shouldClose?(window) ?? true
            }
            self.proxy = proxy
            window.delegate = proxy
        }
    }

    /// Answers `windowShouldClose(_:)` and forwards everything else to the
    /// delegate it replaced.
    final class DelegateProxy: NSObject, NSWindowDelegate {
        private weak var original: NSWindowDelegate?
        private let shouldClose: (NSWindow) -> Bool

        init(original: NSWindowDelegate?, shouldClose: @escaping (NSWindow) -> Bool) {
            self.original = original
            self.shouldClose = shouldClose
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose(sender) else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original
        }
    }
}
