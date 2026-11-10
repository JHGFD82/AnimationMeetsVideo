import Foundation
import Testing
@testable import AnimationMeetsVideo

// The export queue, run with stand-ins for the exporters, the save panel
// and the end announcement (`ExportQueueHarness`).
//
// - `add` returns before the export's task has run. Wait with
//   `try await h.settle { h.exports.hasStarted(a.id) }` before checking
//   `started` or calling `report`.
// - End every test with `try await h.stopAll()`, or with the last export
//   finished and `!h.export.isRunning` settled.
// - Never call `confirmAndCancel()`, `show()`, `askWhereToSave` or
//   `askToStop`, and never call `h.run()` without setting
//   `answerSavePanel`. Each opens a real modal.
// - Give each job its own file name. A place already used is refused.
// - Never count `ExportWindow.runningAnywhere` or `takenDestinations`
//   exactly. They are app-wide, and other suites leave windows in them.
//   Use `contains`, or `running(packageURL: h.export.packageURL)`.
@MainActor @Suite(.serialized) struct ExportWindowTests {
    @Test func exportsRunOneAtATimeInTheOrderAsked() async throws {
        let h = ExportQueueHarness()
        let a = exportJob("Main", to: "A.mov")
        let b = exportJob("Teaser", to: "B.mov")
        let c = exportJob("Main", as: .wavMix, to: "C.wav")
        h.add(a)
        h.add(b)
        h.add(c)
        try await h.settle { h.exports.hasStarted(a.id) }
        #expect(h.export.current?.id == a.id)
        #expect(h.export.queue.map(\.id) == [b.id, c.id])

        h.exports.finish(a.id)
        try await h.settle { h.export.current?.id == b.id }
        h.exports.finish(b.id, report: "Raised 5 dB.")
        try await h.settle { h.export.current?.id == c.id }
        #expect(h.announced == 0)
        h.exports.finish(c.id)
        try await h.settle { !h.export.isRunning }

        #expect(h.exports.started.map(\.id) == [a.id, b.id, c.id])
        #expect(h.exports.started.map(\.timelineName) == ["Main", "Teaser", "Main"])
        #expect(h.export.outcomes.map(\.outcome) == [
            .finished(url: a.destination, report: nil),
            .finished(url: b.destination, report: "Raised 5 dB."),
            .finished(url: c.destination, report: nil),
        ])
        #expect(h.export.outcomes.map(\.timelineName) == ["Main", "Teaser", "Main"])
        #expect(h.announced == 1)
    }

    @Test func aRemovedExportNeverStarts() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        let c = exportJob(to: "C.mov")
        h.add(a)
        h.add(b)
        h.add(c)
        h.export.remove(b.id)
        // Does nothing: a runs, and only waiting exports are removed.
        h.export.remove(a.id)
        #expect(h.export.current?.id == a.id)
        #expect(h.export.queue.map(\.id) == [c.id])

        try await h.settle { h.exports.hasStarted(a.id) }
        h.exports.finish(a.id)
        try await h.settle { h.exports.hasStarted(c.id) }
        h.exports.finish(c.id)
        try await h.settle { !h.export.isRunning }
        #expect(h.exports.started.map(\.id) == [a.id, c.id])
        #expect(h.export.outcomes.count == 2)
    }

    @Test func cancellingStopsTheExportAndEmptiesTheQueue() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        h.add(a)
        h.add(b)
        try await h.settle { h.exports.hasStarted(a.id) }
        h.export.cancel()
        #expect(h.export.queue.isEmpty)

        try await h.settle { !h.export.isRunning }
        #expect(h.exports.started.map(\.id) == [a.id])
        #expect(h.export.outcomes.isEmpty)
        #expect(h.announced == 0)
        #expect(!h.renderer.isExporting)
    }

    @Test func aFailedExportIsNotedAndTheNextStarts() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        h.add(a)
        h.add(b)
        h.exports.fail(a.id, "The disk is full.")
        try await h.settle { h.export.current?.id == b.id }
        #expect(h.export.outcomes.map(\.outcome) == [.failed("The disk is full.")])

        h.exports.finish(b.id)
        try await h.settle { !h.export.isRunning }
        #expect(h.export.outcomes.count == 2)
        #expect(h.announced == 1)
    }

    @Test func renderingWaitsFromTheFirstExportToTheLast() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        let c = exportJob(to: "C.mov")
        #expect(!h.renderer.isExporting)
        h.add(a)
        #expect(h.renderer.isExporting)
        h.add(b)
        h.exports.finish(a.id)
        try await h.settle { h.exports.hasStarted(b.id) }
        #expect(h.renderer.isExporting)
        h.exports.finish(b.id)
        try await h.settle { !h.export.isRunning }
        #expect(!h.renderer.isExporting)

        h.add(c)
        #expect(h.renderer.isExporting)
        try await h.stopAll()
        #expect(!h.renderer.isExporting)
    }

    @Test func outcomesClearOnlyWhenAnExportStartsWithNoneRunning() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        let c = exportJob(to: "C.mov")
        h.add(a)
        h.exports.finish(a.id)
        try await h.settle { !h.export.isRunning }
        #expect(h.export.outcomes.count == 1)

        h.add(b)
        #expect(h.export.outcomes.isEmpty)
        h.add(c)
        h.exports.finish(b.id)
        try await h.settle { h.export.current?.id == c.id }
        #expect(h.export.outcomes.map(\.outcome) == [.finished(url: b.destination, report: nil)])

        try await h.stopAll()
        #expect(h.export.outcomes.count == 1)
    }

    @Test func eachExportStartsAtNoProgress() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        h.add(a)
        h.add(b)
        try await h.settle { h.exports.hasStarted(a.id) }
        h.exports.report(0.5, from: a.id)
        try await h.settle { h.export.progress == 0.5 }

        h.exports.finish(a.id)
        try await h.settle { h.export.current?.id == b.id }
        #expect(h.export.progress == 0)
        try await h.stopAll()
    }

    @Test func aSecondExportIsToldApartByItsTimeline() async throws {
        let h = ExportQueueHarness()
        h.answerSavePanel = { _ in nil }
        h.run()
        h.export.format = .wavStems
        h.run()
        h.export.format = .proRes422
        h.add(exportJob(to: "A.mov"))
        h.run()

        // `EditingProject.empty` is named "Untitled Project", its timeline "Main".
        #expect(h.suggestedNames == ["Untitled Project", "Untitled Project Stems", "Untitled Project Main"])
        // Cancel adds nothing.
        #expect(h.export.queue.isEmpty)
        try await h.stopAll()
    }

    @Test func anExportSavedWhileOneRunsIsQueuedAsPicked() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let picked = URL(filePath: "/tmp/amv-export-tests/B.wav")
        h.add(a)
        h.answerSavePanel = { _ in picked }
        h.export.format = .wavMix
        h.run()

        let queued = try #require(h.export.queue.first)
        #expect(queued.destination == picked)
        #expect(queued.format == .wavMix)
        #expect(queued.timelineName == "Main")
        #expect(h.export.current?.id == a.id)
        try await h.stopAll()
    }
}
