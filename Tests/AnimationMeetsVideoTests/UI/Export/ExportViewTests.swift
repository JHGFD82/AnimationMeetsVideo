import AppKit
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// The Export window's content: how tall it lets the window get, and
/// what its rows say.
@MainActor
struct ExportViewTests {
    /// The height `ExportWindow.show` gives the window with `waiting`
    /// exports queued behind one under way.
    private func windowHeight(waiting: Int) -> CGFloat {
        // SheetFrame reads NSApp.keyWindow once its content scrolls.
        _ = NSApplication.shared
        let export = ExportWindow()
        export.timelineName = "Main"
        export.showQueueWithoutRunning(
            current: exportJob(to: "Trailer.mov"), progress: 0.5,
            queue: (0..<waiting).map { exportJob(as: .wavMix, to: "Trailer \($0).wav") }
        )
        let host = NSHostingView(rootView: ExportView(export: export))
        host.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: Design.SheetWidth.standard, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        return withExtendedLifetime(window) {
            for _ in 0..<4 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
            }
            return host.fittingSize.height
        }
    }

    @Test func windowGrowsWithTheQueueUntilTheScreenIsFull() {
        #expect(windowHeight(waiting: 2) > windowHeight(waiting: 0))
        #expect(windowHeight(waiting: 80) == windowHeight(waiting: 40))
    }
}
