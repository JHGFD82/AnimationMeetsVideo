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
    /// Set once launch has tried to reopen the last project, so the start
    /// sheet doesn't flash up before that.
    @State private var launchChecked = false

    private static let autosaveInterval: Duration = .seconds(60)
    private static let lastProjectKey = "lastProjectPath"

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
                .sheet(isPresented: Binding(get: { launchChecked && projectURL == nil }, set: { _ in })) {
                    ProjectStartView(onNew: newProject, onOpen: openProject)
                }
                .task {
                    if !launchChecked {
                        await reopenLastProject()
                        launchChecked = true
                    }
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

                Divider()

                Toggle("Copy Imported Media into Project", isOn: $project.copiesMediaOnImport)
                    .disabled(projectURL == nil)
            }
        }
    }

    /// Asks where to save the new project and creates its package at once,
    /// so imports and analysis have somewhere to go from the start.
    private func newProject() {
        guard confirmDiscardingCurrentProject() else { return }
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: ProjectStore.packageExtension, conformingTo: .package) {
            panel.allowedContentTypes = [type]
        }
        panel.title = "New Project"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Untitled Project"
        let copyOption = NSButton(checkboxWithTitle: "Copy imported media into the project", target: nil, action: nil)
        copyOption.state = .on
        copyOption.toolTip = "Off: imported files stay where they are and the project refers to them there."
        let accessory = NSStackView(views: [copyOption])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != ProjectStore.packageExtension {
            url.appendPathExtension(ProjectStore.packageExtension)
        }

        var fresh = EditingProject.empty
        fresh.name = url.deletingPathExtension().lastPathComponent
        fresh.copiesMediaOnImport = copyOption.state == .on
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try replaceExisting(at: url)
                try ProjectStore.preparePackage(at: url)
                let lock = try ProjectLock.acquire(at: url)
                let saved = try await ProjectStore.save(fresh, to: url)
                project = saved
                history.reset(to: saved)
                savedProject = saved
                lastAutosaved = nil
                projectURL = url
                projectLock = lock
                fileMonitor.track(package: url)
                analysis.reset(packageURL: url)
                replacement.reset()
                rememberLastProject(url)
            } catch {
                showAlert(title: "Couldn't Create Project", message: error.localizedDescription)
            }
        }
    }

    /// The save panel has already asked whether to replace what's at `url`,
    /// so it goes to the Trash, unless it's a project open somewhere else.
    private func replaceExisting(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if (try? ProjectStore.validatePackage(at: url)) != nil, !isOpenProject(url) {
            // Throws if another window or app has it open; released right away.
            _ = try ProjectLock.acquire(at: url)
        }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
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
        Task { await openProject(at: url) }
    }

    /// Opens the project used last, if it's still there. Without one the
    /// start sheet asks for a new project or another to open.
    private func reopenLastProject() async {
        guard let path = UserDefaults.standard.string(forKey: Self.lastProjectKey) else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard (try? ProjectStore.validatePackage(at: url)) != nil else {
            UserDefaults.standard.removeObject(forKey: Self.lastProjectKey)
            return
        }
        await openProject(at: url)
    }

    private func rememberLastProject(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.lastProjectKey)
    }

    private func openProject(at url: URL) async {
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
            rememberLastProject(url)
            analysis.reset(
                tracks: result.changeScores, references: result.references,
                thumbnailed: result.assetsWithThumbnails, beats: result.beats, packageURL: url
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
                // Imports are copied as they come in, so only Save As copies,
                // carrying along what the previous package holds.
                let isNewLocation = projectURL.map { !isSamePackage($0, url) } ?? true
                guard let copying = isNewLocation ? chooseMediaToCopy(for: project, into: url) : [] else { return }
                let snapshot = project
                let scoresToSave = analysis.unsavedTracks
                let referencesToSave = analysis.unsavedReferences
                let thumbnailsToSave = analysis.unsavedThumbnails
                let beatsToSave = analysis.unsavedBeats
                let beatsToDiscard = analysis.discardedBeats
                let saved = try await ProjectStore.save(
                    snapshot, to: url, copying: copying,
                    changeScores: scoresToSave, references: referencesToSave,
                    thumbnails: thumbnailsToSave, beats: beatsToSave,
                    discardingBeats: beatsToDiscard, previousPackageURL: projectURL
                )
                analysis.markSaved(scoresToSave.keys)
                analysis.markReferencesSaved(referencesToSave.keys)
                analysis.markThumbnailsSaved(thumbnailsToSave.keys)
                analysis.markBeatsSaved(beatsToSave.keys)
                analysis.markBeatsDiscarded(beatsToDiscard)
                analysis.dropForgottenReferences(in: saved)
                // Edits made while saving stay; only the media locations change.
                history.adopt { $0.applyMediaLocations(from: saved) }
                project.applyMediaLocations(from: saved)
                savedProject = saved
                lastAutosaved = nil
                projectURL = url
                projectLock = lock
                fileMonitor.track(package: url)
                analysis.packageURL = url
                rememberLastProject(url)
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
                    thumbnailed: result.assetsWithThumbnails, beats: result.beats, packageURL: url
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
        if let projectLock, isSamePackage(projectLock.packageURL, url) {
            return projectLock
        }
        return try ProjectLock.acquire(at: url)
    }

    private func isOpenProject(_ url: URL) -> Bool {
        projectURL.map { isSamePackage($0, url) } ?? false
    }

    private func isSamePackage(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Picks which media Save As copies into the new package: what the
    /// current package holds. Same-volume copies are APFS clones that cost no
    /// space, so they happen without asking; copies that use real disk space
    /// need confirmation. Returns nil to cancel.
    private func chooseMediaToCopy(for project: EditingProject, into packageURL: URL) -> Set<UUID>? {
        let candidates = ProjectStore.mediaToCopy(in: project, into: packageURL, from: projectURL)
        var selected = Set(candidates.filter(\.isClone).map(\.clipID))
        let heavy = candidates.filter { !$0.isClone }
        guard !heavy.isEmpty else { return selected }

        let total = heavy.reduce(Int64(0)) { $0 + $1.byteCount }
        switch MediaCopyPrompt.ask(fileCount: heavy.count, byteCount: total) {
        case .copy:
            selected.formUnion(heavy.map(\.clipID))
            return selected
        case .referenceInPlace:
            return selected
        case nil:
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

