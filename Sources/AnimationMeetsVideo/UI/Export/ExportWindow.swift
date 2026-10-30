import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The Export window, opened from the toolbar's Export… or File > Export…
/// (⌘E). Its format and sound menus used to sit in the editor's toolbar,
/// where one left with the keyboard kept the arrow keys from the
/// playhead; in a window of their own they have the keys only while it is
/// in front. It runs the export too, so closing it leaves one going, with
/// its progress on the toolbar, and it comes back when the export ends.
/// Stopping an export, or closing the project or quitting while one runs,
/// asks first (`confirmStopping`).
@MainActor
@Observable
final class ExportWindow {
    var format = ExportFormat.proRes422
    /// The timeline Export exports, as the editor shows it.
    var timelineName = ""
    /// Pasted effect changes still to resolve in what it draws, which
    /// block the export (see `EditorToolbar.exportProject`).
    var pasteChangeCount = 0
    private(set) var isRunning = false
    private(set) var progress: Double = 0
    /// How the last export ended, shown until the next starts.
    private(set) var outcome: Outcome?
    /// Exports what the window shows, once pasted changes are dealt with.
    @ObservationIgnored var onExport: () -> Void = {}
    /// Opens the Paste Changes list in the editor.
    @ObservationIgnored var onReviewPasteChanges: () -> Void = {}
    /// The window of the editor this exports from, which Paste Changes is
    /// shown over and whose closing stops the export.
    @ObservationIgnored weak var editorWindow: NSWindow?
    /// The project's package, whose closing stops the export.
    @ObservationIgnored var packageURL: URL?
    /// Where the running export is going.
    @ObservationIgnored private var destination: URL?
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
    /// project\") would, and stops them on yes. True when there are none
    /// or they were stopped; false to keep them going, and the window or
    /// app open.
    static func confirmStopping(_ exports: [ExportWindow], because reason: String) -> Bool {
        guard !exports.isEmpty else { return true }
        let alert = NSAlert()
        if exports.count == 1, let name = exports[0].destination?.lastPathComponent {
            alert.messageText = "Stop exporting \u{201C}\(name)\u{201D}?"
        } else {
            alert.messageText = "Stop \(exports.count) exports?"
        }
        let what = exports.count == 1 ? "the export" : "the exports"
        alert.informativeText = "\(reason) stops \(what), and what is exported so far is deleted."
        // Return keeps the export going; stopping it takes a click or Tab.
        alert.addButton(withTitle: "Keep Exporting")
        let stop = alert.addButton(withTitle: "Stop Export")
        stop.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        for export in exports { export.cancel() }
        return true
    }

    enum Outcome: Equatable {
        case finished(url: URL, report: String?)
        case failed(String)
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
        host.sizingOptions = [.preferredContentSize]
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

    func cancel() {
        task?.cancel()
    }

    /// Stops the running export once the person agrees to.
    func confirmAndCancel() {
        _ = Self.confirmStopping([self], because: "Stopping")
    }

    /// Asks where to save, then exports `timelineID` of `project` there
    /// in the format and sound picked. `renderer` pauses meanwhile, and a
    /// ProRes 422 export reuses its renders.
    func run(project: EditingProject, timelineID: UUID, renderer: RenderScheduler) {
        guard !isRunning else { return }
        let format = format
        let panel = NSSavePanel()
        switch format {
        case .proRes422, .proRes4444: panel.allowedContentTypes = [.quickTimeMovie]
        case .wavMix: panel.allowedContentTypes = [.wav]
        case .wavStems:
            // The name is a new folder's, with a file per layer in it.
            panel.message = "Stems are saved in a new folder with this name, one file for each layer with sound."
        }
        panel.nameFieldStringValue = format == .wavStems ? "\(project.name) Stems" : project.name
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // As the window's menus (`ExportView`) keep them.
        let defaults = UserDefaults.standard
        let target = defaults.string(forKey: Preferences.exportLoudness).flatMap { LoudnessTarget(rawValue: $0) } ?? .asMixed
        let tracks = defaults.string(forKey: Preferences.exportAudioTracks).flatMap { ExportAudioTracks(rawValue: $0) } ?? .mix
        let cache = renderer.cache
        progress = 0
        outcome = nil
        destination = url
        isRunning = true
        renderer.setExporting(true)
        task = Task {
            defer {
                task = nil
                isRunning = false
                renderer.setExporting(false)
            }
            let progress: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor in self.progress = fraction }
            }
            // Only shown once the export is done.
            let report = ReportBox()
            do {
                switch format {
                case .proRes422, .proRes4444:
                    try await CompositionExporter.export(
                        project: project, timelineID: timelineID, preset: format.movie ?? .proRes422,
                        loudness: target, audioTracks: tracks, to: url, cache: cache, progress: progress,
                        onMastered: { report.value = $0 }
                    )
                case .wavMix:
                    report.value = try await AudioExport.exportMix(
                        project: project, timelineID: timelineID, loudness: target, to: url, progress: progress
                    )
                case .wavStems:
                    try await AudioExport.exportStems(
                        project: project, timelineID: timelineID, named: project.name, in: url, progress: progress
                    )
                }
                outcome = .finished(url: url, report: report.value?.summary)
            } catch is CancellationError {
                // The user cancelled; nothing to report.
                return
            } catch {
                outcome = .failed(ErrorAdvice.sentence(for: error))
            }
            // The outcome is shown in the window, back if it was closed.
            // A long export may finish with the app behind another.
            show()
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    /// Shows `outcome` as if an export had ended, for a picture of the
    /// view (`UISnapshots`).
    func showOutcomeWithoutRunning(_ outcome: Outcome?) {
        self.outcome = outcome
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
