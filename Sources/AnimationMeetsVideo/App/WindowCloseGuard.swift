import AppKit
import SwiftUI

/// Asks `shouldClose` before this view's window closes, so a question about
/// unsaved changes appears while the window is still on screen rather than
/// after it is gone. SwiftUI owns the window's delegate, so the guard sits
/// in front of it and passes every other delegate call through.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: () -> Bool

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.shouldClose = shouldClose
        return view
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.shouldClose = shouldClose
    }

    final class GuardView: NSView {
        var shouldClose: (() -> Bool)?
        private var proxy: DelegateProxy?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !(window.delegate is DelegateProxy) else { return }
            let proxy = DelegateProxy(original: window.delegate) { [weak self] in
                self?.shouldClose?() ?? true
            }
            self.proxy = proxy
            window.delegate = proxy
        }
    }

    /// Answers `windowShouldClose(_:)` and forwards everything else to the
    /// delegate it replaced.
    final class DelegateProxy: NSObject, NSWindowDelegate {
        private weak var original: NSWindowDelegate?
        private let shouldClose: () -> Bool

        init(original: NSWindowDelegate?, shouldClose: @escaping () -> Bool) {
            self.original = original
            self.shouldClose = shouldClose
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
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
