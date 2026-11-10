import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A job exporting `project`'s root timeline, as `ExportWindow.run`
/// builds one once the save panel answers `file`.
@MainActor
func exportJob(_ timeline: String = "Main", as format: ExportFormat = .proRes422, to file: String,
               project: EditingProject = .empty) -> ExportWindow.Job {
    ExportWindow.Job(
        project: project, timelineID: project.rootTimelineID, timelineName: timeline, format: format,
        loudness: .asMixed, audioTracks: .mix, destination: URL(filePath: "/tmp/amv-export-tests/\(file)")
    )
}

/// Stands in for the exporters behind `ExportWindow.perform`: each
/// export runs until the test finishes, fails or stops it, and writes
/// nothing, so a queue can be stepped through one export at a time.
@MainActor
final class StandInExports {
    private enum Ending { case finish(String?), fail(String) }
    private struct Failure: LocalizedError { let errorDescription: String? }

    /// The jobs started, in order, as `perform` was given them.
    private(set) var started: [ExportWindow.Job] = []
    private var endings: [ExportWindow.Job.ID: Ending] = [:]
    private var progress: [ExportWindow.Job.ID: @Sendable (Double) -> Void] = [:]

    func hasStarted(_ id: ExportWindow.Job.ID) -> Bool { started.contains { $0.id == id } }
    func finish(_ id: ExportWindow.Job.ID, report: String? = nil) { endings[id] = .finish(report) }
    func fail(_ id: ExportWindow.Job.ID, _ message: String) { endings[id] = .fail(message) }
    /// Reports `fraction` as export `id` does, even after it has ended,
    /// as a last progress hop can.
    func report(_ fraction: Double, from id: ExportWindow.Job.ID) { progress[id]?(fraction) }

    func run(_ job: ExportWindow.Job, progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        started.append(job)
        self.progress[job.id] = progress
        while true {
            switch endings[job.id] {
            case .finish(let report): return report
            case .fail(let message): throw Failure(errorDescription: message)
            // Throws CancellationError once the export is stopped.
            case nil: try await Task.sleep(for: .milliseconds(2))
            }
        }
    }
}

/// An Export window whose exporters, save panel and end announcement
/// are stood in for, so its queue runs in a test with no window, panel,
/// alert or file.
@MainActor
final class ExportQueueHarness {
    let export = ExportWindow()
    /// Held here, since the window keeps the editor's renderer weakly.
    let renderer = RenderScheduler()
    let exports = StandInExports()
    /// How often the window was brought back as the exports ended.
    private(set) var announced = 0
    /// The names the save panel was offered, in order.
    private(set) var suggestedNames: [String] = []
    /// What the save panel answers, given the name it suggests; nil is Cancel.
    var answerSavePanel: (String) -> URL? = { _ in
        Issue.record("A save panel was not expected")
        return nil
    }

    init() {
        // Its own, so `ExportWindow.running(packageURL:)` finds only it.
        export.packageURL = URL(filePath: "/tmp/amv-export-tests-\(UUID().uuidString).amv")
        export.perform = { [exports] job, _, progress in try await exports.run(job, progress: progress) }
        export.announceEnd = { [weak self] _ in self?.announced += 1 }
        export.chooseDestination = { [weak self] name, _ in
            guard let self else { return nil }
            suggestedNames.append(name)
            return answerSavePanel(name)
        }
    }

    /// Adds `job` as Export… does once its save panel answers.
    func add(_ job: ExportWindow.Job) {
        export.add(job, clearingOutcomes: !export.isRunning, renderer: renderer)
    }

    /// Clicks Export… for `project`'s root timeline.
    func run(_ project: EditingProject = .empty) {
        export.run(project: project, timelineID: project.rootTimelineID, renderer: renderer)
    }

    /// Waits for `condition`, as the queue moves on between main-actor turns.
    func settle(
        _ what: String = "the export queue", sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async throws {
        try await waitUntil(what, every: .milliseconds(2), sourceLocation: sourceLocation, condition)
    }

    /// Stops whatever runs and waits for it to end. Every test ends with
    /// this, so no stand-in export keeps polling.
    func stopAll(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        export.cancel()
        try await settle("the exports to stop", sourceLocation: sourceLocation) { !export.isRunning }
    }
}
