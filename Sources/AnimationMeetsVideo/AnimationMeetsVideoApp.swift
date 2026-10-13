import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// SwiftPM executables have no app bundle/Info.plist, so without this the
/// process never becomes the frontmost app and its window never appears.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AnimationMeetsVideoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var project: EditingProject
    @State private var history: ProjectHistory
    @State private var projectURL: URL?
    @State private var projectLock: ProjectLock?
    /// The project as last saved or opened, to tell whether there are unsaved changes.
    @State private var savedProject: EditingProject
    @State private var lastAutosaved: EditingProject?
    @State private var analysis = AssetAnalysis()
    @State private var replacement = MediaReplacementController()
    @State private var fileMonitor = ProjectFileMonitor()
    /// True while the project file is being written or reloaded.
    @State private var isBusy = false

    private static let autosaveInterval: Duration = .seconds(60)

    private var hasUnsavedChanges: Bool { project != savedProject }

    init() {
        let initial = EditingProject.empty
        _project = State(initialValue: initial)
        _savedProject = State(initialValue: initial)
        _history = State(initialValue: ProjectHistory(project: initial))
    }

    var body: some Scene {
        WindowGroup("Animation Meets Video") {
            EditorView(
                project: $project, history: history, analysis: analysis,
                replacement: replacement, packageURL: projectURL
            )
                .mediaReplacementDialogs(project: $project, controller: replacement)
                .onExternalProjectChange { checkForExternalProjectChange() }
                .frame(minWidth: 1_100, minHeight: 700)
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: Self.autosaveInterval)
                        autosave()
                    }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    newProject()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Open Project…") {
                    openProject()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button("Save Project") {
                    saveProject()
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Save Project As…") {
                    saveProject(forcePanel: true)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }

    private func newProject() {
        guard confirmDiscardingCurrentProject() else { return }
        project = EditingProject.empty
        history.reset(to: project)
        savedProject = project
        lastAutosaved = nil
        projectURL = nil
        projectLock = nil
        analysis.reset()
        replacement.reset()
        fileMonitor.stop()
    }

    private func openProject() {
        guard confirmDiscardingCurrentProject() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.folder, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose a project (.\(ProjectStore.packageExtension)) to open."
        guard panel.runModal() == .OK, let selection = panel.url else { return }
        let url = ProjectStore.packageURL(forSelection: selection)

        Task {
            do {
                try ProjectStore.validatePackage(at: url)
                let lock = try lockForProject(at: url)
                let result = try await ProjectStore.load(from: url)
                project = result.project
                history.reset(to: result.project)
                savedProject = result.project
                lastAutosaved = nil
                projectURL = url
                projectLock = lock
                fileMonitor.track(package: url)
                analysis.reset(
                    tracks: result.changeScores, references: result.references,
                    thumbnailed: result.assetsWithThumbnails, beats: result.beats
                )
                analysis.analyzeMissing(in: result.project)
                replacement.reset()
                replacement.markChanged(result.changedMedia)
                if !result.changedMedia.isEmpty {
                    replacement.notice = .init(
                        title: "Media Changed Since Last Saved",
                        message: "\(result.changedMedia.count) media file(s) were changed outside the app. Control-click each one in the Clips list and choose \u{201C}File Changed — Check Sync…\u{201D}."
                    )
                }
                if !result.missingMedia.isEmpty {
                    let names = result.missingMedia.map(\.lastPathComponent).joined(separator: "\n")
                    showAlert(
                        title: "Some Media Couldn't Be Opened",
                        message: "These files are missing or unreadable, so their clips were removed from the timelines:\n\n\(names)"
                    )
                }
            } catch {
                showAlert(title: "Couldn't Open Project", message: error.localizedDescription)
            }
        }
    }

    private func saveProject(forcePanel: Bool = false) {
        var destination = forcePanel ? nil : projectURL
        if destination == nil {
            let panel = NSSavePanel()
            if let type = UTType(filenameExtension: ProjectStore.packageExtension, conformingTo: .package) {
                panel.allowedContentTypes = [type]
            }
            panel.nameFieldStringValue = project.name
            guard panel.runModal() == .OK, var url = panel.url else { return }
            if url.pathExtension != ProjectStore.packageExtension {
                url.appendPathExtension(ProjectStore.packageExtension)
            }
            destination = url
        }
        guard let url = destination else { return }

        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try ProjectStore.preparePackage(at: url)
                let lock = try lockForProject(at: url)
                guard let copying = chooseMediaToCopy(for: project, into: url) else { return }
                let snapshot = project
                let scoresToSave = analysis.unsavedTracks
                let referencesToSave = analysis.unsavedReferences
                let thumbnailsToSave = analysis.unsavedThumbnails
                let beatsToSave = analysis.unsavedBeats
                let saved = try await ProjectStore.save(
                    snapshot, to: url, copying: copying,
                    changeScores: scoresToSave, references: referencesToSave,
                    thumbnails: thumbnailsToSave, beats: beatsToSave
                )
                analysis.markSaved(scoresToSave.keys)
                analysis.markReferencesSaved(referencesToSave.keys)
                analysis.markThumbnailsSaved(thumbnailsToSave.keys)
                analysis.markBeatsSaved(beatsToSave.keys)
                // Edits made while saving stay; only the media locations change.
                history.adopt { $0.applyMediaLocations(from: saved) }
                project.applyMediaLocations(from: saved)
                savedProject = saved
                lastAutosaved = nil
                projectURL = url
                projectLock = lock
                fileMonitor.track(package: url)
            } catch {
                showAlert(title: "Couldn't Save Project", message: error.localizedDescription)
            }
        }
    }

    /// Picks up edits made to `project.json` outside the app. With nothing
    /// unsaved the file's version replaces the project; with unsaved edits
    /// the person chooses. Either way the switch is an ordinary edit, so
    /// undo brings the previous version back.
    private func checkForExternalProjectChange() {
        guard let url = projectURL, !isBusy, replacement.session == nil,
              let change = fileMonitor.pendingChange()
        else { return }

        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let result = try await ProjectStore.load(from: url)
                if project != savedProject {
                    let alert = NSAlert()
                    alert.messageText = "The project file was changed outside the app"
                    alert.informativeText = "You also have unsaved changes. If you keep them, the next save overwrites the file. If you use the file's version, you can undo to get your changes back."
                    alert.addButton(withTitle: "Keep My Changes")
                    alert.addButton(withTitle: "Use the File's Version")
                    guard alert.runModal() == .alertSecondButtonReturn else {
                        fileMonitor.acknowledge(change)
                        return
                    }
                }
                project = result.project
                savedProject = result.project
                lastAutosaved = nil
                fileMonitor.acknowledge(change)
                analysis.reset(
                    tracks: result.changeScores, references: result.references,
                    thumbnailed: result.assetsWithThumbnails, beats: result.beats
                )
                analysis.analyzeMissing(in: result.project)
                replacement.reset()
                replacement.markChanged(result.changedMedia)
                if !result.missingMedia.isEmpty {
                    let names = result.missingMedia.map(\.lastPathComponent).joined(separator: "\n")
                    showAlert(
                        title: "Some Media Couldn't Be Opened",
                        message: "These files are missing or unreadable, so their clips were removed from the timelines:\n\n\(names)"
                    )
                }
            } catch {
                fileMonitor.acknowledge(change)
                showAlert(
                    title: "The Project File Changed but Couldn't Be Read",
                    message: "\(error.localizedDescription)\n\nThe open project is unchanged. Saving will overwrite the file."
                )
            }
        }
    }

    /// The lock for `url`: the one already held if it's the current project,
    /// otherwise a new one (throws if another instance has the project open).
    /// A new lock replaces the old one only when the caller assigns it.
    private func lockForProject(at url: URL) throws -> ProjectLock {
        if let projectLock,
           projectLock.packageURL.standardizedFileURL.resolvingSymlinksInPath()
            == url.standardizedFileURL.resolvingSymlinksInPath() {
            return projectLock
        }
        return try ProjectLock.acquire(at: url)
    }

    /// Picks which media to copy into the package. Same-volume copies are
    /// APFS clones that cost no space, so they happen without asking; copies
    /// that use real disk space need confirmation. Returns nil to cancel.
    private func chooseMediaToCopy(for project: EditingProject, into packageURL: URL) -> Set<UUID>? {
        let candidates = ProjectStore.mediaToCopy(in: project, into: packageURL)
        var selected = Set(candidates.filter(\.isClone).map(\.clipID))
        let heavy = candidates.filter { !$0.isClone }
        guard !heavy.isEmpty else { return selected }

        let total = heavy.reduce(Int64(0)) { $0 + $1.byteCount }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Copy \(heavy.count) media file\(heavy.count == 1 ? "" : "s") into the project?"
        alert.informativeText = "\(size) will be copied because the files are on a different volume than the project, so it uses real disk space. You can leave them where they are and the project will reference them in place."
        alert.addButton(withTitle: "Copy \(size)")
        alert.addButton(withTitle: "Reference in Place")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            selected.formUnion(heavy.map(\.clipID))
            return selected
        case .alertSecondButtonReturn:
            return selected
        default:
            return nil
        }
    }

    /// Writes a recovery copy into the package's `Backups/` folder. Only for
    /// projects that have been saved once (there is no package before that),
    /// and only when something changed since the last save or autosave.
    private func autosave() {
        guard let url = projectURL, hasUnsavedChanges, project != lastAutosaved else { return }
        do {
            try ProjectStore.writeBackup(of: project, in: url)
            lastAutosaved = project
        } catch {
            NSLog("Autosave failed: \(error.localizedDescription)")
        }
    }

    private func confirmDiscardingCurrentProject() -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Replace the current project?"
        alert.informativeText = "Changes you haven't saved will be lost."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

