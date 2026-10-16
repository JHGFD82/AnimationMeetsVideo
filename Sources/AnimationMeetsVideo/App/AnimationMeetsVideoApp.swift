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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { TerminationGuard.shared.shouldTerminate?() ?? .terminateNow }
    }
}

/// Lets the app's state answer whether it may quit, since the delegate
/// can't see it: unsaved changes are offered for saving first.
@MainActor
final class TerminationGuard {
    static let shared = TerminationGuard()
    var shouldTerminate: (() -> NSApplication.TerminateReply)?
    /// Opens the editor window again, for when closing the last one asked
    /// to quit and the person cancelled.
    var reopenWindow: (() -> Void)?
}

/// Hands the window-opening action to `TerminationGuard`.
private struct WindowReopenerRegistration: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                TerminationGuard.shared.reopenWindow = { openWindow(id: AnimationMeetsVideoApp.windowID) }
            }
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
    /// The latest save asked for. Each save waits for the one before, so
    /// two never write the package at once.
    @State private var saveInProgress: Task<Bool, Never>?
    /// Set once launch has tried to reopen the last project, so the start
    /// sheet doesn't flash up before that.
    @State private var launchChecked = false
    @State private var showsProjectSettings = false

    private static let autosaveInterval: Duration = .seconds(60)
    private static let lastProjectKey = "lastProjectPath"
    static let windowID = "editor"

    private var hasUnsavedChanges: Bool { project != savedProject }

    init() {
        let initial = EditingProject.empty
        _project = State(initialValue: initial)
        _savedProject = State(initialValue: initial)
        _history = State(initialValue: ProjectHistory(project: initial))
    }

    var body: some Scene {
        WindowGroup("Animation Meets Video", id: Self.windowID) {
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
                .background(WindowReopenerRegistration())
                .background(
                    Color.clear.sheet(isPresented: $showsProjectSettings) {
                        ProjectSettingsView(project: project) { name, copies in
                            var changed = project
                            changed.name = name
                            changed.copiesMediaOnImport = copies
                            if changed != project { project = changed }
                        }
                    }
                )
                .task {
                    TerminationGuard.shared.shouldTerminate = { confirmQuit() }
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
                    Task { await saveProject() }
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Save Project As…") {
                    Task { await saveProject(forcePanel: true) }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Project Settings…") {
                    showsProjectSettings = true
                }
                .keyboardShortcut("j", modifiers: [.command])
                .disabled(projectURL == nil)
            }
            TimelineCommands()
        }
    }

    /// Asks where to save the new project and creates its package at once,
    /// so imports and analysis have somewhere to go from the start.
    private func newProject() {
        Task {
            guard await confirmDiscardingCurrentProject() else { return }
            await createProject()
        }
    }

    private func createProject() async {
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
        Task {
            guard await confirmDiscardingCurrentProject() else { return }
            chooseProjectToOpen()
        }
    }

    private func chooseProjectToOpen() {
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
            let saved = try await ProjectStore.load(from: url)
            // Work an autosave holds that was never saved, as after quitting
            // without saving or a crash, is offered back.
            var restored: ProjectLoadResult?
            if let backup = ProjectStore.unsavedBackup(in: url) {
                if askToRestore(backup, name: saved.project.name) {
                    restored = try? await ProjectStore.load(from: url, projectFile: backup)
                } else {
                    ProjectStore.markBackupsSeen(in: url)
                }
            }
            let result = restored ?? saved
            history.reset(to: saved.project)
            savedProject = saved.project
            // Restoring is an ordinary edit on top of the saved version, so
            // it shows as unsaved and can be undone.
            project = result.project
            lastAutosaved = restored?.project
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
            replacement.markMissing(result.offlineMedia)
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
                    message: "These files are missing or unreadable:\n\n\(names)\n\nTheir clips stay in the project and play as gaps until the files are back. Put them back, or Control-click one in the Clips list and choose \u{201C}Replace Media…\u{201D}."
                )
            }
        } catch {
            showAlert(title: "Couldn't Open Project", message: error.localizedDescription)
        }
    }

    /// Returns whether the project was saved. A save asked for while
    /// another runs (pressing Save twice, or quitting during a save) starts
    /// once that one is done.
    @discardableResult
    private func saveProject(forcePanel: Bool = false) async -> Bool {
        let previous = saveInProgress
        let save = Task {
            _ = await previous?.value
            return await performSave(forcePanel: forcePanel)
        }
        saveInProgress = save
        let saved = await save.value
        if saveInProgress == save { saveInProgress = nil }
        return saved
    }

    private func performSave(forcePanel: Bool) async -> Bool {
        var destination = forcePanel ? nil : projectURL
        if destination == nil {
            let panel = NSSavePanel()
            if let type = UTType(filenameExtension: ProjectStore.packageExtension, conformingTo: .package) {
                panel.allowedContentTypes = [type]
            }
            panel.nameFieldStringValue = project.name
            guard panel.runModal() == .OK, var url = panel.url else { return false }
            if url.pathExtension != ProjectStore.packageExtension {
                url.appendPathExtension(ProjectStore.packageExtension)
            }
            destination = url
        }
        guard let url = destination else { return false }
        // Only a destination picked in the panel, where replacing it was
        // confirmed, is cleared; saving onto the open project isn't a replace.
        let replacesExisting = !isOpenProject(url)
        if replacesExisting, usesMedia(inside: url) {
            showAlert(
                title: "Couldn't Save Project",
                message: "This project uses media stored inside \u{201C}\(url.lastPathComponent)\u{201D}, so it can't replace it. Choose another name or place."
            )
            return false
        }

        do {
            isBusy = true
            defer { isBusy = false }
            do {
                // Otherwise the old package's media, backups and render
                // cache would be mixed into this one.
                if replacesExisting {
                    try replaceExisting(at: url)
                }
                try ProjectStore.preparePackage(at: url)
                let lock = try lockForProject(at: url)
                // Imports are copied as they come in, so only Save As copies,
                // carrying along what the previous package holds.
                let isNewLocation = projectURL.map { !isSamePackage($0, url) } ?? true
                guard let copying = isNewLocation ? chooseMediaToCopy(for: project, into: url) : [] else { return false }
                // Results finished while saving somewhere new would go into
                // the old package after its reference data was copied, so
                // they are held until the save is done.
                if isNewLocation {
                    analysis.packageURL = nil
                }
                defer {
                    if isNewLocation {
                        let package = projectURL
                        analysis.packageURL = package
                        Task { await analysis.writeHeldResults() }
                    }
                }
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
                history.adoptMediaLocations(of: snapshot, from: saved)
                project.applyMediaLocations(from: saved)
                savedProject = saved
                lastAutosaved = nil
                projectURL = url
                projectLock = lock
                fileMonitor.track(package: url)
                analysis.packageURL = url
                rememberLastProject(url)
                return true
            } catch {
                showAlert(title: "Couldn't Save Project", message: error.localizedDescription)
                return false
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
                replacement.markMissing(result.offlineMedia)
                if !result.missingMedia.isEmpty {
                    let names = result.missingMedia.map(\.lastPathComponent).joined(separator: "\n")
                    showAlert(
                        title: "Some Media Couldn't Be Opened",
                        message: "These files are missing or unreadable:\n\n\(names)\n\nTheir clips stay in the project and play as gaps until the files are back. Put them back, or Control-click one in the Clips list and choose \u{201C}Replace Media…\u{201D}."
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

    /// Whether any of the project's media lives inside `packageURL`, which
    /// replacing that package would take away.
    private func usesMedia(inside packageURL: URL) -> Bool {
        let folder = packageURL.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return project.clips.contains { clip in
            clip.url.map { $0.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(folder) } ?? false
        }
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

    private enum UnsavedChoice { case save, discard, cancel }

    /// Asks what to do with unsaved changes before they would be lost.
    private func askAboutUnsavedChanges(_ question: String) -> UnsavedChoice {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "If you don't save, your changes since the last save are lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Before another project replaces this one: saves, discards or cancels.
    private func confirmDiscardingCurrentProject() async -> Bool {
        guard hasUnsavedChanges, let url = projectURL else { return true }
        switch askAboutUnsavedChanges("Save changes to \u{201C}\(project.name)\u{201D} first?") {
        case .save: return await saveProject()
        case .discard:
            ProjectStore.markBackupsSeen(in: url)
            return true
        case .cancel: return false
        }
    }

    /// Before quitting, including by closing the window: unsaved changes are
    /// saved, discarded, or keep the app open.
    private func confirmQuit() -> NSApplication.TerminateReply {
        guard hasUnsavedChanges, let url = projectURL else { return .terminateNow }
        switch askAboutUnsavedChanges("Save changes to \u{201C}\(project.name)\u{201D} before quitting?") {
        case .save:
            Task {
                let saved = await saveProject()
                if !saved { reopenWindowIfClosed() }
                NSApp.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        case .discard:
            ProjectStore.markBackupsSeen(in: url)
            return .terminateNow
        case .cancel:
            reopenWindowIfClosed()
            return .terminateCancel
        }
    }

    /// Closing the last window asks to quit; when that's cancelled the
    /// window comes back, still holding the project.
    private func reopenWindowIfClosed() {
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        TerminationGuard.shared.reopenWindow?()
    }

    private func askToRestore(_ backup: URL, name: String) -> Bool {
        let date = (try? backup.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let alert = NSAlert()
        alert.messageText = "Restore unsaved changes to \u{201C}\(name)\u{201D}?"
        alert.informativeText = "An automatic backup from \(date.formatted(date: .abbreviated, time: .shortened)) has changes that were never saved. Restoring them is an ordinary edit: you can undo it, and nothing is written until you save."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Don't Restore")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

