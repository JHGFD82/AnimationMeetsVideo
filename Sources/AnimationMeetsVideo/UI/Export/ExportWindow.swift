import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The Export window, opened from the toolbar's Export… or File > Export…
/// (⌘E). Its format and sound menus used to sit in the editor's toolbar,
/// where one left with the keyboard kept the arrow keys from the
/// playhead; in a window of their own they have the keys only while it is
/// in front. It runs the export too, so closing it leaves one going, with
/// its progress on the toolbar, and it comes back when the exports end.
/// Export… while one runs queues the timeline the editor shows then, in
/// the format and sound picked then, to start once those before it end;
/// the queue is listed in the window. Stopping an export, or closing the
/// project or quitting while one runs, asks first (`confirmStopping`).
@MainActor
@Observable
final class ExportWindow {
    var format = ExportFormat.proRes422
    /// The timeline Export exports, as the editor shows it.
    var timelineName = ""
    /// Pasted effect changes still to resolve in what it draws, which
    /// block the export (see `EditorToolbar.exportProject`).
    var pasteChangeCount = 0
    /// The export under way, if any.
    private(set) var current: Job?
    /// Exports waiting for the one under way, the first to start first.
    private(set) var queue: [Job] = []
    private(set) var progress: Double = 0
    /// How the exports since the window was last idle ended, oldest
    /// first, shown until an export starts with none running.
    private(set) var outcomes: [Ended] = []
    var isRunning: Bool { current != nil }
    /// Exports what the window shows, once pasted changes are dealt with.
    @ObservationIgnored var onExport: () -> Void = {}
    /// Opens the Paste Changes list in the editor.
    @ObservationIgnored var onReviewPasteChanges: () -> Void = {}
    /// The window of the editor this exports from, which Paste Changes is
    /// shown over and whose closing stops the export.
    @ObservationIgnored weak var editorWindow: NSWindow?
    /// The project's package, whose closing stops the export.
    @ObservationIgnored var packageURL: URL?
    /// The editor's, which pauses while exports run.
    @ObservationIgnored private weak var renderer: RenderScheduler?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?
    /// Every editor's, for closing a project or quitting to find the
    /// exports that would stop.
    private static let all = NSHashTable<ExportWindow>.weakObjects()

    init() {
        Self.all.add(self)
    }

    /// The exports running from `editor`, or from any editor on the
    /// project at `packageURL`.
    static func running(in editor: NSWindow? = nil, packageURL: URL? = nil) -> [ExportWindow] {
        all.allObjects.filter { export in
            export.isRunning
                && ((editor != nil && export.editorWindow === editor)
                    || (packageURL != nil && export.packageURL == packageURL))
        }
    }

    /// Every export running in the app.
    static var runningAnywhere: [ExportWindow] {
        all.allObjects.filter(\.isRunning)
    }

    /// Asks whether to stop `exports`, which `reason` (\"Closing the
    /// project\") would, and stops them, and those queued behind them, on
    /// yes. True when there are none or they were stopped; false to keep
    /// them going, and the window or app open.
    static func confirmStopping(_ exports: [ExportWindow], because reason: String) -> Bool {
        guard !exports.isEmpty else { return true }
        let jobs = exports.flatMap { export in [export.current].compactMap { $0 } + export.queue }
        guard askToStop(jobs, because: reason) else { return false }
        for export in exports { export.cancel() }
        return true
    }

    /// Asks whether to stop `jobs`; true on yes.
    private static func askToStop(_ jobs: [Job], because reason: String) -> Bool {
        let alert = NSAlert()
        if jobs.count == 1 {
            alert.messageText = "Stop exporting \u{201C}\(jobs[0].destination.lastPathComponent)\u{201D}?"
        } else {
            alert.messageText = "Stop \(jobs.count) exports?"
        }
        let what = jobs.count == 1 ? "the export" : "the exports"
        alert.informativeText = "\(reason) stops \(what), and what is exported so far is deleted."
        // Return keeps the export going; stopping it takes a click or Tab.
        alert.addButton(withTitle: "Keep Exporting")
        let stop = alert.addButton(withTitle: "Stop Export")
        stop.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    enum Outcome: Equatable {
        case finished(url: URL, report: String?)
        case failed(String)
    }

    /// One export as it was asked for, with the project as it was then,
    /// so edits made while it waits don't change what it exports.
    struct Job: Identifiable {
        let id = UUID()
        let project: EditingProject
        let timelineID: UUID
        let timelineName: String
        let format: ExportFormat
        let loudness: LoudnessTarget
        let audioTracks: ExportAudioTracks
        let destination: URL
    }

    /// How one export ended.
    struct Ended: Identifiable, Equatable {
        let id = UUID()
        let timelineName: String
        let outcome: Outcome
    }

    /// Opens the window, or brings it to the front.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Design.SheetWidth.standard, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Export"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: ExportView(export: self))
        // The window follows the content's height, which grows by a
        // finished export's report, a blocking note or the queue;
        // preferred size alone left it at its first height with the rest
        // cut off.
        host.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        window.contentView = host
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didClose() }
        }
        window.setFrameAutosaveName("Export")
        if window.frame.origin == .zero { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    /// Brings the editor forward, for Paste Changes shown over it.
    func showEditor() {
        editorWindow?.makeKeyAndOrderFront(nil)
    }

    /// Stops the export under way and drops those waiting.
    func cancel() {
        queue.removeAll()
        task?.cancel()
    }

    /// Stops the export under way once the person agrees to; the next
    /// one waiting starts.
    func confirmAndCancel() {
        guard let current, Self.askToStop([current], because: "Stopping") else { return }
        task?.cancel()
    }

    /// Takes a waiting export out of the queue.
    func remove(_ id: Job.ID) {
        queue.removeAll { $0.id == id }
    }

    /// Asks where to save, then exports `timelineID` of `project` there
    /// in the format and sound picked: now, or, while another export
    /// runs, once those queued before it end. `renderer` pauses
    /// meanwhile, and a ProRes 422 export reuses its renders.
    func run(project: EditingProject, timelineID: UUID, renderer: RenderScheduler) {
        let format = format
        let panel = NSSavePanel()
        switch format {
        case .proRes422, .proRes4444: panel.allowedContentTypes = [.quickTimeMovie]
        case .wavMix: panel.allowedContentTypes = [.wav]
        case .wavStems:
            // The name is a new folder's, with a file per layer in it.
            panel.message = "Stems are saved in a new folder with this name, one file for each layer with sound."
        }
        let timelineName = project.timeline(id: timelineID)?.name ?? timelineName
        // A second export of the project is told apart by its timeline.
        let baseName = isRunning && !timelineName.isEmpty ? "\(project.name) \(timelineName)" : project.name
        panel.nameFieldStringValue = format == .wavStems ? "\(baseName) Stems" : baseName
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // As the window's menus (`ExportView`) keep them.
        let defaults = UserDefaults.standard
        let job = Job(
            project: project,
            timelineID: timelineID,
            timelineName: timelineName,
            format: format,
            loudness: defaults.string(forKey: Preferences.exportLoudness).flatMap { LoudnessTarget(rawValue: $0) } ?? .asMixed,
            audioTracks: defaults.string(forKey: Preferences.exportAudioTracks).flatMap { ExportAudioTracks(rawValue: $0) } ?? .mix,
            destination: url
        )
        self.renderer = renderer
        if isRunning {
            queue.append(job)
        } else {
            outcomes = []
            renderer.setExporting(true)
            start(job)
        }
    }

    private func start(_ job: Job) {
        let cache = renderer?.cache
        progress = 0
        current = job
        task = Task {
            let progress: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor in self.progress = fraction }
            }
            // Only shown once the export is done.
            let report = ReportBox()
            let url = job.destination
            var outcome: Outcome?
            do {
                switch job.format {
                case .proRes422, .proRes4444:
                    try await CompositionExporter.export(
                        project: job.project, timelineID: job.timelineID, preset: job.format.movie ?? .proRes422,
                        loudness: job.loudness, audioTracks: job.audioTracks, to: url, cache: cache,
                        progress: progress, onMastered: { report.value = $0 }
                    )
                case .wavMix:
                    report.value = try await AudioExport.exportMix(
                        project: job.project, timelineID: job.timelineID, loudness: job.loudness, to: url,
                        progress: progress
                    )
                case .wavStems:
                    try await AudioExport.exportStems(
                        project: job.project, timelineID: job.timelineID, named: job.project.name, in: url,
                        progress: progress
                    )
                }
                outcome = .finished(url: url, report: report.value?.summary)
            } catch is CancellationError {
                // Stopped by the person; nothing to report.
            } catch {
                outcome = .failed(ErrorAdvice.sentence(for: error))
            }
            ended(job, outcome)
        }
    }

    /// Notes how `job` ended and starts the next one waiting, or, with
    /// none, lets rendering go on and shows how they all ended.
    private func ended(_ job: Job, _ outcome: Outcome?) {
        task = nil
        if let outcome { outcomes.append(Ended(timelineName: job.timelineName, outcome: outcome)) }
        if !queue.isEmpty {
            start(queue.removeFirst())
            return
        }
        current = nil
        renderer?.setExporting(false)
        // Not when the last was stopped: by the person, in the window, or
        // by its project closing, which closed the window too.
        guard outcome != nil else { return }
        // The outcomes are shown in the window, back if it was closed.
        // A long export may finish with the app behind another.
        show()
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Shows `outcome` as if an export had ended, for a picture of the
    /// view (`UISnapshots`).
    func showOutcomeWithoutRunning(_ outcome: Outcome?, timelineName: String = "Main") {
        outcomes = outcome.map { [Ended(timelineName: timelineName, outcome: $0)] } ?? []
    }

    /// Shows `current` under way, `progress` along, with `queue` waiting
    /// behind it, for a picture of the view (`UISnapshots`).
    func showQueueWithoutRunning(current: Job, progress: Double, queue: [Job]) {
        self.current = current
        self.progress = progress
        self.queue = queue
    }

    private func didClose() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
    }
}

/// Hands the mastering report out of the export's callback.
private final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LoudnessMastering.Report?
    var value: LoudnessMastering.Report? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
