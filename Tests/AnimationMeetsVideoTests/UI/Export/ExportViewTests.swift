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

    @Test func severalOutcomesEachNameTheirTimeline() {
        let saved = ExportWindow.Ended(timelineName: "Main", outcome: .finished(url: URL(filePath: "/tmp/Trailer.mov"), report: nil))
        let failed = ExportWindow.Ended(timelineName: "Teaser", outcome: .failed("The disk is full."))
        #expect(ExportView.message(for: saved, showsTimeline: true) == "\u{201C}Main\u{201D}: \u{201C}Trailer.mov\u{201D} was saved.")
        #expect(ExportView.message(for: failed, showsTimeline: true) == "\u{201C}Teaser\u{201D}: Export failed. The disk is full.")
        #expect(ExportView.message(for: saved, showsTimeline: false) == "\u{201C}Trailer.mov\u{201D} was saved.")
    }

    @Test func aStoppedExportSaysSo() {
        let stopped = ExportWindow.Ended(timelineName: "Teaser", outcome: .stopped(url: URL(filePath: "/tmp/Trailer Teaser.mov")))
        #expect(
            ExportView.message(for: stopped, showsTimeline: true)
                == "\u{201C}Teaser\u{201D}: Stopped exporting \u{201C}Trailer Teaser.mov\u{201D}."
        )
    }

    @Test func removeButtonsOfTheSameTimelineReadApart() {
        let movie = ExportView.removeLabel(for: exportJob("Main", as: .proRes422, to: "Trailer.mov"))
        let mix = ExportView.removeLabel(for: exportJob("Main", as: .wavMix, to: "Trailer.wav"))
        #expect(movie != mix)
        #expect(mix == "Remove \u{201C}Main\u{201D} as WAV Mix, \u{201C}Trailer.wav\u{201D}, from the queue")
    }
}
