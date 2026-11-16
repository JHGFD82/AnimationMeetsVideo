import CoreMedia
import Foundation
import Observation

/// What a window shows, for `amv.timeline`, `amv.selection` and
/// `amv.playhead`: kept up to date by the project window's editor, read
/// when a run begins. Not observed: nothing redraws when it changes.
@MainActor
final class ScriptWindowState {
    /// The timeline the editor shows.
    var timelineID: UUID?
    /// The clip selected on its own.
    var selection: TimelineSelection?
    /// Clips picked together with a lasso (two or more), which the
    /// timeline keeps apart from `selection`.
    var groupSelection: Set<UUID> = []
    /// The playhead's time, read when asked.
    var playhead: () -> CMTime = { .zero }

    /// The run's `context`: the timeline shown, the clips selected on it,
    /// top layer first and then by time, and the playhead.
    func context(in project: EditingProject) -> JSONValue {
        let timelineID = timelineID.flatMap { project.timeline(id: $0)?.id } ?? project.rootTimelineID
        var picked = groupSelection
        if let selection, selection.timelineID == timelineID { picked.insert(selection.timelineClipID) }
        let clips = (project.timeline(id: timelineID)?.layers ?? []).flatMap { layer in
            layer.clips.filter { picked.contains($0.id) }.sorted { $0.startOffset < $1.startOffset }
        }
        return [
            "timeline": JSONValue(timelineID),
            "selection": .array(clips.map { [JSONValue(timelineID), JSONValue($0.id)] }),
            "playhead": ScriptTime.json(playhead()),
        ]
    }
}

/// What a run works on: a window's project, its history, and what it
/// knows besides.
@MainActor
struct ScriptTarget {
    let projectState: ProjectState
    let history: ProjectHistory
    let packageURL: URL?
    let sceneTracks: [UUID: ChangeScoreTrack]
    let window: ScriptWindowState

    init(session: ProjectSession) {
        projectState = session.projectState
        history = session.history
        packageURL = session.projectURL
        sceneTracks = session.analysis.tracks
        window = session.scriptWindow
    }
}

/// Runs scripts and console lines on a project, each as one undo step
/// (see docs/python-scripting.md, "One run, one undo step").
///
/// A run reads a snapshot of the project, through the `ProjectBridge`,
/// and its changes go to the bridge's working copy. If it ends without
/// raising, the working copy is written to the project once, and the
/// history records it as one step named for the script. A run that
/// raises, is stopped, or whose helper dies writes nothing.
@MainActor
@Observable
final class ScriptRunner {
    static let shared = ScriptRunner(helper: PythonHelpers.scripts)

    /// The run under way, for the sheet that names it and offers Stop.
    struct Run: Equatable {
        var name: String
        var kind: HelperRequest.Kind
        /// The project it runs on.
        var projectID: UUID
        var started: Date
    }

    /// How a run ended, for whoever started it.
    enum Outcome: Equatable {
        /// It finished; `changed` says whether it was written as a step.
        case finished(changed: Bool, display: String?)
        /// It raised, or was stopped.
        case failed(ScriptFailure)
        /// The project changed while it ran (a file reloaded, say), so
        /// its changes weren't kept.
        case projectChanged
        /// It couldn't run: no Python, or the helper failed.
        case couldNotRun(String)
    }

    private(set) var current: Run?
    @ObservationIgnored let helper: any ScriptHelper
    /// Where printed text and results go: the console.
    @ObservationIgnored var transcript: ScriptTranscript

    init(helper: any ScriptHelper, transcript: ScriptTranscript = .shared) {
        self.helper = helper
        self.transcript = transcript
    }

    var isRunning: Bool { current != nil }

    /// Runs `request` on the target's project. One run at a time: while
    /// one is under way this does nothing and says so.
    @discardableResult
    func run(_ request: HelperRequest, named name: String, on target: ScriptTarget) async -> Outcome {
        guard current == nil else { return .couldNotRun("A script is already running.") }
        let snapshot = target.projectState.value
        current = Run(name: name, kind: request.kind, projectID: snapshot.id, started: Date())
        defer { current = nil }

        var request = request
        request.context = target.window.context(in: snapshot)
        let bridge = ProjectBridge(project: snapshot, context: ProjectBridge.Context(
            packageURL: target.packageURL,
            sceneTracks: target.sceneTracks,
            beatTracks: DetectedBeats.shared.tracks,
            locks: target.projectState.clipLocks
        ))
        let transcript = transcript
        let end: ScriptRunEnd
        do {
            end = try await helper.run(
                request,
                output: { output in
                    // The main queue keeps the order the text came in.
                    DispatchQueue.main.async { MainActor.assumeIsolated { transcript.append(output) } }
                },
                answer: { await bridge.answer($0) }
            )
        } catch {
            let reason = error.localizedDescription
            transcript.append(.problem(reason))
            return .couldNotRun(reason)
        }
        // What was printed is shown before how it ended.
        await Self.mainQueueDrained()

        switch end {
        case .failed(let failure):
            transcript.append(.failure(failure))
            return .failed(failure)
        case .finished(let display):
            if let display { transcript.append(.result(display)) }
            guard await bridge.hasChanges else { return .finished(changed: false, display: display) }
            // Anything written meanwhile (a file reloaded, analysis
            // arriving) would be lost under the run's copy.
            guard target.projectState.value.editCount == snapshot.editCount else {
                transcript.append(.problem("The project changed while \u{201C}\(name)\u{201D} ran, so its changes weren't kept. Run it again."))
                return .projectChanged
            }
            let working = await bridge.working
            target.history.nameNextStep(Self.stepName(for: name, kind: request.kind))
            target.projectState.value = working
            return .finished(changed: true, display: display)
        }
    }

    /// Stops the run under way.
    func stop() {
        guard current != nil else { return }
        Task { await helper.stop() }
    }

    /// The Edit menu's name for a run's step.
    static func stepName(for name: String, kind: HelperRequest.Kind) -> String {
        kind == .line ? "Python Console" : "Run \u{201C}\(name)\u{201D}"
    }

    /// Waits for what was queued on the main queue before now to run.
    private static func mainQueueDrained() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// What the console shows: lines typed, what runs printed, results and
/// tracebacks. One for the app, as there is one console.
@MainActor
@Observable
final class ScriptTranscript {
    static let shared = ScriptTranscript()

    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            /// A line typed into the console.
            case input
            case output
            case errorOutput
            /// A console line's value.
            case result
            /// A traceback, or why something couldn't run.
            case error
            /// The helper's or the app's own note.
            case note
        }

        let id = UUID()
        var kind: Kind
        var text: String
    }

    /// How much is kept, in entries; older ones go.
    static let kept = 2_000

    private(set) var entries: [Entry] = []
    /// Lines typed, oldest first, for the up and down arrows.
    private(set) var history: [String] = []

    enum Item {
        case input(String)
        case result(String)
        case failure(ScriptFailure)
        case problem(String)
        case note(String)
    }

    func append(_ output: ScriptOutput) {
        let kind: Entry.Kind = switch output.stream {
        case .stdout: .output
        case .stderr: .errorOutput
        case .note: .note
        }
        // Printed text arrives in pieces; one entry holds a run of them.
        if let last = entries.last, last.kind == kind, kind != .note {
            entries[entries.count - 1].text += output.text
        } else {
            add(Entry(kind: kind, text: output.text))
        }
    }

    func append(_ item: Item) {
        switch item {
        case .input(let line):
            add(Entry(kind: .input, text: line))
            if history.last != line { history.append(line) }
        case .result(let text): add(Entry(kind: .result, text: text))
        case .failure(let failure):
            add(Entry(kind: .error, text: failure.traceback.isEmpty ? failure.summary : failure.traceback))
        case .problem(let text): add(Entry(kind: .error, text: text))
        case .note(let text): add(Entry(kind: .note, text: text))
        }
    }

    func clear() {
        entries = []
    }

    private func add(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.kept { entries.removeFirst(entries.count - Self.kept) }
    }
}
