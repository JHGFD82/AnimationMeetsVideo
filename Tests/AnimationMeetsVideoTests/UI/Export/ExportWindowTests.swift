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
//   `askToStop`, never call `confirmStopping` without `ask:`, and never
//   call `h.run()` without setting `answerSavePanel`. Each opens a real
//   modal.
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

    @Test func stoppingTheExportUnderWayStartsTheNext() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        h.add(a)
        h.add(b)
        try await h.settle { h.exports.hasStarted(a.id) }
        #expect(h.export.stop(a.id))

        try await h.settle { h.exports.hasStarted(b.id) }
        #expect(h.exports.started.map(\.id) == [a.id, b.id])
        #expect(h.export.outcomes.isEmpty)
        #expect(h.renderer.isExporting)
        #expect(h.announced == 0)

        h.exports.finish(b.id)
        try await h.settle { !h.export.isRunning }
        #expect(h.announced == 1)
    }

    // What Stop Export… does once its question closes: by then the export
    // asked about may have ended and the next started, which goes on.
    @Test func stoppingAnExportThatHasEndedLeavesTheNextGoing() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        h.add(a)
        h.add(b)
        h.exports.finish(a.id)
        try await h.settle { h.exports.hasStarted(b.id) }
        #expect(!h.export.stop(a.id))

        try await Task.sleep(for: .milliseconds(30))
        #expect(h.export.current?.id == b.id)
        #expect(h.exports.started.count == 2)
        try await h.stopAll()
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

    // Whether Export… clears the outcomes is decided by what ran when it
    // was clicked, not by what runs once its save panel answers. An export
    // can't be ended inside the stand-in panel, which holds the main actor
    // the queue needs, so this starts one there instead.
    @Test func outcomesClearWhenTheWindowWasIdleAsExportWasClicked() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        h.add(a)
        h.exports.finish(a.id)
        try await h.settle { !h.export.isRunning }
        #expect(h.export.outcomes.count == 1)

        h.answerSavePanel = { [weak h] _ in
            guard let h else { return nil }
            h.export.add(b, clearingOutcomes: false, renderer: h.renderer)
            return URL(filePath: "/tmp/amv-export-tests/C.mov")
        }
        h.run()

        #expect(h.export.outcomes.isEmpty)
        #expect(h.export.current?.id == b.id)
        #expect(h.export.queue.count == 1)
        try await h.stopAll()
    }

    @Test func anExportSavedWhileOneRunsKeepsHowTheLastEnded() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let x = exportJob(to: "X.mov")
        h.add(a)
        h.exports.finish(a.id)
        try await h.settle { !h.export.isRunning }
        #expect(h.export.outcomes.count == 1)

        h.export.add(x, clearingOutcomes: false, renderer: h.renderer)
        #expect(h.export.outcomes.map(\.outcome) == [.finished(url: a.destination, report: nil)])
        try await h.stopAll()
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

    @Test func progressFromAnEndedExportIsDropped() {
        let export = ExportWindow()
        let ended = exportJob(to: "A.mov")
        let next = exportJob(to: "B.mov")
        export.showQueueWithoutRunning(current: next, progress: 0, queue: [])
        export.setProgress(0.97, of: ended.id)
        #expect(export.progress == 0)
        export.setProgress(0.3, of: next.id)
        #expect(export.progress == 0.3)
    }

    // A progress hop of an export that has ended, landing after the next
    // one started, leaves the next one's progress alone.
    @Test func lateProgressFromAnEndedExportIsDropped() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        h.add(a)
        h.add(b)
        try await h.settle { h.exports.hasStarted(a.id) }
        h.exports.finish(a.id)
        try await h.settle { h.exports.hasStarted(b.id) }
        h.exports.report(0.25, from: b.id)
        try await h.settle { h.export.progress == 0.25 }

        h.exports.report(0.97, from: a.id)
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.export.progress == 0.25)
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

    @Test func takenDestinationsListEveryExportUnderWayOrWaiting() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "\(UUID().uuidString).mov")
        let b = exportJob(to: "\(UUID().uuidString).mov")
        h.add(a)
        h.add(b)
        #expect(ExportWindow.takenDestinations.contains(a.destination))
        #expect(ExportWindow.takenDestinations.contains(b.destination))

        try await h.stopAll()
        #expect(!ExportWindow.takenDestinations.contains(a.destination))
        #expect(!ExportWindow.takenDestinations.contains(b.destination))
    }

    @Test func theSuggestedNameSkipsOnesUnderWayOrWaiting() async throws {
        let h = ExportQueueHarness()
        var project = EditingProject.empty
        project.name = "Trailer \(UUID().uuidString)"
        h.add(exportJob(to: "\(project.name).mov", project: project))
        h.add(exportJob(to: "\(project.name) Main.mov", project: project))
        h.answerSavePanel = { _ in nil }
        h.run(project)

        #expect(h.suggestedNames.last == "\(project.name) Main 2")
        try await h.stopAll()
    }

    @Test func aPlaceInUseIsRefused() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "\(UUID().uuidString).mov")
        h.add(a)
        h.answerSavePanel = { _ in a.destination }
        h.run()

        #expect(h.export.queue.isEmpty)
        #expect(h.export.current?.id == a.id)
        #expect(h.told.count == 1)
        try await h.stopAll()
    }

    // Closing a project or quitting asks about every job first, and stops
    // them only once the close or quit can no longer be called off
    // (`stopExports`). `ask` stands in for the alert.

    @Test func agreeingToStopStopsNothingYet() {
        let export = ExportWindow()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        let c = exportJob(to: "C.mov")
        export.showQueueWithoutRunning(current: a, progress: 0, queue: [b, c])
        var asked: [ExportWindow.Job] = []
        let agreed = ExportWindow.confirmStopping([export], because: "Quitting") { jobs, _ in
            asked = jobs
            return true
        }
        #expect(agreed)
        #expect(asked.map(\.id) == [a.id, b.id, c.id])
        #expect(export.queue.count == 2)
        #expect(export.isRunning)
    }

    @Test func keepingExportsAnswersNo() {
        let export = ExportWindow()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        export.showQueueWithoutRunning(current: a, progress: 0, queue: [b])
        let agreed = ExportWindow.confirmStopping([export], because: "Quitting") { _, _ in false }
        #expect(!agreed)
        #expect(export.queue.map(\.id) == [b.id])
        #expect(export.current?.id == a.id)
    }

    @Test func noExportsAsksNothing() {
        let agreed = ExportWindow.confirmStopping([], because: "Quitting") { _, _ in
            Issue.record("Nothing should be asked with no exports")
            return false
        }
        #expect(agreed)
    }

    @Test func stoppingDropsTheQueueAndIsNotAskedAboutAgain() {
        let export = ExportWindow()
        let packageURL = URL(filePath: "/tmp/amv-export-tests-\(UUID().uuidString).amv")
        export.packageURL = packageURL
        export.showQueueWithoutRunning(
            current: exportJob(to: "A.mov"), progress: 0, queue: [exportJob(to: "B.mov")]
        )
        #expect(ExportWindow.running(packageURL: packageURL).map(ObjectIdentifier.init) == [ObjectIdentifier(export)])

        ExportWindow.stopExports([export])
        #expect(export.queue.isEmpty)
        #expect(ExportWindow.running(packageURL: packageURL).isEmpty)
        #expect(!ExportWindow.runningAnywhere.contains { $0 === export })
    }

    @Test func cancellingAnIdleWindowLeavesItFindable() {
        let export = ExportWindow()
        let packageURL = URL(filePath: "/tmp/amv-export-tests-\(UUID().uuidString).amv")
        export.packageURL = packageURL
        export.cancel()
        export.showQueueWithoutRunning(current: exportJob(to: "A.mov"), progress: 0, queue: [])
        #expect(ExportWindow.running(packageURL: packageURL).map(ObjectIdentifier.init) == [ObjectIdentifier(export)])
    }

    @Test func agreeingToQuitStopsNothingUntilItGoesAhead() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        h.add(a)
        h.add(b)
        try await h.settle { h.exports.hasStarted(a.id) }
        #expect(ExportWindow.confirmStopping([h.export], because: "Quitting") { _, _ in true })

        try await Task.sleep(for: .milliseconds(30))
        #expect(h.export.current?.id == a.id)
        #expect(h.export.queue.map(\.id) == [b.id])

        ExportWindow.stopExports([h.export])
        // Winding down, it isn't asked about again.
        #expect(ExportWindow.running(packageURL: h.export.packageURL).isEmpty)
        try await h.settle { !h.export.isRunning }
        #expect(h.exports.started.map(\.id) == [a.id])

        let c = exportJob(to: "C.mov")
        h.add(c)
        #expect(ExportWindow.running(packageURL: h.export.packageURL).map(ObjectIdentifier.init)
            == [ObjectIdentifier(h.export)])
        try await h.stopAll()
    }
}
