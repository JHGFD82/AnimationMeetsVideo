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
        #expect(h.export.outcomes.map(\.outcome) == [.stopped(url: a.destination)])
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
        #expect(h.export.outcomes.map(\.outcome) == [.stopped(url: a.destination)])
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
        #expect(h.export.outcomes.map(\.outcome) == [
            .finished(url: b.destination, report: nil),
            .stopped(url: c.destination),
        ])
    }

    @Test func aStoppedExportLeavesALineAndTheNextStarts() async throws {
        let h = ExportQueueHarness()
        let a = exportJob(to: "A.mov")
        let b = exportJob(to: "B.mov")
        h.add(a)
        h.add(b)
        try await h.settle { h.exports.hasStarted(a.id) }
        #expect(h.export.stop(a.id))

        try await h.settle { h.exports.hasStarted(b.id) }
        #expect(h.export.outcomes.map(\.outcome) == [.stopped(url: a.destination)])
        try await h.stopAll()
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

    @Test func stopTextWithNoQueueIsUnchanged() {
        let text = ExportWindow.stopText(for: exportJob(to: "Trailer.mov"), queue: [])
        #expect(text.message == "Stop exporting \u{201C}Trailer.mov\u{201D}?")
        #expect(text.information == "Stopping stops the export, and what is exported so far is deleted.")
    }

    @Test func stopTextNamesTheNextWaiting() {
        let current = exportJob(to: "Trailer.mov")
        let teaser = exportJob("Teaser", to: "Trailer Teaser.mov")
        let one = ExportWindow.stopText(for: current, queue: [teaser])
        #expect(one.message == "Stop exporting \u{201C}Trailer.mov\u{201D}?")
        #expect(one.information
            == "What is exported so far is deleted, and \u{201C}Trailer Teaser.mov\u{201D}, waiting in the queue, starts at once. Stop All takes it out of the queue too.")

        let three = ExportWindow.stopText(
            for: current, queue: [teaser, exportJob(to: "B.mov"), exportJob(to: "C.mov")]
        )
        #expect(three.information.contains("\u{201C}Trailer Teaser.mov\u{201D}, next of the 3 waiting"))
        #expect(three.information.contains("Stop All takes them all out of the queue too."))
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

    /// Stems saved into a folder holding files of their names would
    /// replace them unasked (code-review-notes.md, F72): Export… names
    /// them and asks, Cancel queues nothing, and Replace queues the job
    /// with those files and no others agreed to.
    @Test func stemsAskBeforeReplacingFilesOfTheirNames() async throws {
        let tone = try AudioMixSupport.tone(seconds: 1)
        defer { try? FileManager.default.removeItem(at: tone) }
        let (project, _, _) = try AudioMixSupport.project(playing: tone)
        let folder = FileManager.default.temporaryDirectory.appending(path: "amv-stems-ask-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stem = try #require(AudioExport.stemFiles(project: project, timelineID: project.rootTimelineID, named: project.name, in: folder).first).url
        try Data("An earlier stem".utf8).write(to: stem)

        let h = ExportQueueHarness()
        h.export.format = .wavStems
        h.answerSavePanel = { _ in folder }
        h.answerReplace = { _ in false }
        h.run(project)
        #expect(h.askedToReplace.map { $0.map(\.lastPathComponent) } == [[stem.lastPathComponent]])
        #expect(!h.export.isRunning)

        h.answerReplace = { _ in true }
        h.run(project)
        try await h.settle { !h.exports.started.isEmpty }
        let job = try #require(h.exports.started.first)
        #expect(job.replacing.map(\.lastPathComponent) == [stem.lastPathComponent])
        try await h.stopAll()
    }

    /// With no file of their names in the folder, stems ask nothing.
    @Test func stemsIntoANewFolderAskNothing() async throws {
        let tone = try AudioMixSupport.tone(seconds: 1)
        defer { try? FileManager.default.removeItem(at: tone) }
        let (project, _, _) = try AudioMixSupport.project(playing: tone)
        let folder = FileManager.default.temporaryDirectory.appending(path: "amv-stems-new-\(UUID().uuidString)", directoryHint: .isDirectory)

        let h = ExportQueueHarness()
        h.export.format = .wavStems
        h.answerSavePanel = { _ in folder }
        h.run(project)
        try await h.settle { !h.exports.started.isEmpty }
        #expect(h.askedToReplace.isEmpty)
        #expect(h.exports.started.first?.replacing == [])
        try await h.stopAll()
    }

    @Test func theReplaceQuestionNamesTheFilesAndTheFolder() {
        let folder = URL(filePath: "/tmp/Cut Stems", directoryHint: .isDirectory)
        let one = ExportWindow.replaceStemsText([folder.appending(path: "Cut - Music 1.wav")], in: folder)
        #expect(one.message == "Replace \u{201C}Cut - Music 1.wav\u{201D} in \u{201C}Cut Stems\u{201D}?")
        let files = (1...7).map { folder.appending(path: "Cut - Sound \($0).wav") }
        let many = ExportWindow.replaceStemsText(files, in: folder)
        #expect(many.message == "Replace 7 files in \u{201C}Cut Stems\u{201D}?")
        #expect(many.information.contains("\u{201C}Cut - Sound 5.wav\u{201D}, and 2 more"))
        #expect(!many.information.contains("Sound 6"))
    }
}
