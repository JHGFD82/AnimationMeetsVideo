import AppKit
import Observation
import SwiftUI

/// One open project and everything that goes with it: its state and undo
/// history, its package and lock, its analysis and file watching. Each
/// editor window has one (`ProjectWindow`), so several projects can be
/// open at once, and copied clips paste from one into another.
///
/// A session starts empty, showing the start sheet, and opens or creates
/// one project for its lifetime; opening another project opens another
/// window (`ProjectWindows`).
@MainActor
@Observable
final class ProjectSession {
    /// The project, through which a value drag is held (see `ProjectState`).
    let projectState: ProjectState
    let history: ProjectHistory
    let analysis = AssetAnalysis()
    let replacement = MediaReplacementController()
    /// Whether automatic saves and backups are being written, shown in the
    /// toolbar when not.
    let autosaveStatus = AutosaveStatus()
    @ObservationIgnored let fileMonitor = ProjectFileMonitor()

    private(set) var projectURL: URL?
    /// The project as last saved or opened, to tell whether there are unsaved changes.
    private(set) var savedProject: EditingProject
    var showsProjectSettings = false
    /// Set once the person has settled unsaved changes for closing the
    /// window, so closing it again isn't asked about.
    @ObservationIgnored var closeConfirmed = false

    @ObservationIgnored private var projectLock: ProjectLock?
    @ObservationIgnored private var lastAutosaved: EditingProject?
    /// True while the project file is being written or reloaded.
    @ObservationIgnored private var isBusy = false
    /// The latest save asked for. Each save waits for the one before, so
    /// two never write the package at once.
    @ObservationIgnored private var saveInProgress: Task<Bool, Never>?
    /// Tells the window which project it shows, so opening the same
    /// project again brings this window forward (see `ProjectWindow`).
    @ObservationIgnored var onProjectURLChange: ((URL?) -> Void)?

    static let autosaveInterval: Duration = .seconds(60)

    init() {
        let initial = EditingProject.empty
        projectState = ProjectState(initial)
        savedProject = initial
        history = ProjectHistory(project: initial)
        ProjectWindows.shared.register(self)
    }

    var project: EditingProject {
        get { projectState.value }
        set { projectState.value = newValue }
    }

    var hasUnsavedChanges: Bool { project != savedProject }

    /// No project yet: the window shows the start sheet.
    var isEmpty: Bool { projectURL == nil }

    func isOpen(_ url: URL) -> Bool {
        projectURL.map { Self.isSamePackage($0, url) } ?? false
    }

    static func isSamePackage(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func setProjectURL(_ url: URL?) {
        projectURL = url
        onProjectURLChange?(url)
        ProjectWindows.shared.openProjectsChanged()
    }

    // MARK: - Creating and opening

    /// Asks where to save a new project and makes its package at once, so
    /// imports and analysis have somewhere to go from the start. Returns
    /// the package, for a window to open; nil if cancelled or it failed.
    static func createProject() async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ProjectStore.packageType]
        panel.title = "New Project"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Untitled Project"
        let copyOption = NSButton(checkboxWithTitle: "Copy imported media into the project", target: nil, action: nil)
        copyOption.state = .on
        copyOption.toolTip = "Off: imported files stay where they are and the project refers to them there."
        let accessory = NSStackView(views: [copyOption])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        if url.pathExtension != ProjectStore.packageExtension {
            url.appendPathExtension(ProjectStore.packageExtension)
        }
        if ProjectWindows.shared.session(showing: url) != nil {
            showAlert(title: "Couldn't Create Project", message: "\u{201C}\(url.lastPathComponent)\u{201D} is open in another window. Close it there first, or choose another name.")
            return nil
        }

        var fresh = EditingProject.empty
        fresh.name = url.deletingPathExtension().lastPathComponent
        fresh.copiesMediaOnImport = copyOption.state == .on
        do {
            // The save panel has already asked whether to replace what's there.
            try await ProjectStore.trashPackage(at: url, checkingLock: true)
            try ProjectStore.preparePackage(at: url)
            _ = try await ProjectStore.save(fresh, to: url)
            return url
        } catch {
            showAlert(title: "Couldn't Create Project", message: ErrorAdvice.sentence(for: error))
            return nil
        }
    }

    /// Asks for a project to open. Returns its package, for a window to open.
    static func chooseProjectToOpen() -> URL? {
        let panel = NSOpenPanel()
        // Folders too: a project copied somewhere that dropped its package
        // flag shows as a folder until it's opened again.
        panel.allowedContentTypes = [ProjectStore.packageType, .folder, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose a project (.\(ProjectStore.packageExtension)) to open."
        guard panel.runModal() == .OK, let selection = panel.url else { return nil }
        return ProjectStore.packageURL(forSelection: selection)
    }

    /// Opens the project at `url` in this session, which must be empty.
    /// Returns whether it opened.
    @discardableResult
    func open(_ url: URL) async -> Bool {
        guard isEmpty else { return isOpen(url) }
        do {
            try ProjectStore.validatePackage(at: url)
            let lock = try ProjectLock.acquire(at: url)
            ProjectStore.markAsPackage(url)
            let saved = try await ProjectStore.load(from: url)
            // Work an autosave holds that was never saved, as after quitting
            // without saving or a crash, is offered back.
            var restored: ProjectLoadResult?
            if let backup = ProjectStore.unsavedBackup(in: url) {
                if askToRestore(backup, name: saved.project.name) {
                    restored = try? await ProjectStore.load(from: url, projectFile: backup)
                } else {
                    await ProjectStore.markBackupsSeenQueued(in: url)
                }
            }
            let result = restored ?? saved
            history.reset(to: saved.project)
            savedProject = saved.project
            // Restoring is an ordinary edit on top of the saved version, so
            // it shows as unsaved and can be undone.
            project = result.project
            lastAutosaved = restored?.project
            autosaveStatus.succeeded()
            projectLock = lock
            fileMonitor.track(package: url)
            setProjectURL(url)
            ProjectWindows.shared.remember(url)
            analysis.reset(
                tracks: result.changeScores, references: result.references,
                thumbnailed: result.assetsWithThumbnails, beats: result.beats,
                originalScores: result.originalScores, sources: result.analysisSources,
                rejected: result.rejectedAnalysis, packageURL: url
            )
            analysis.update(with: result.project)
            replacement.reset()
            replacement.markChanged(result.changedMedia)
            replacement.markMissing(result.offlineMedia)
            reportMediaProblems(in: result)
            return true
        } catch {
            Self.showAlert(title: "Couldn't Open Project", message: ErrorAdvice.sentence(for: error))
            return false
        }
    }

    // MARK: - Saving

    /// Returns whether the project was saved. A save asked for while
    /// another runs (pressing Save twice, or quitting during a save) starts
    /// once that one is done.
    @discardableResult
    func save(forcePanel: Bool = false) async -> Bool {
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
            panel.allowedContentTypes = [ProjectStore.packageType]
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
        let replacesExisting = !isOpen(url)
        if replacesExisting, usesMedia(inside: url) {
            Self.showAlert(
                title: "Couldn't Save Project",
                message: "This project uses media stored inside \u{201C}\(url.lastPathComponent)\u{201D}, so it can't replace it. Choose another name or place."
            )
            return false
        }
        if replacesExisting, ProjectWindows.shared.session(showing: url) != nil {
            Self.showAlert(
                title: "Couldn't Save Project",
                message: "\u{201C}\(url.lastPathComponent)\u{201D} is open in another window. Close it there first, or choose another name."
            )
            return false
        }

        isBusy = true
        defer { isBusy = false }
        do {
            // Otherwise the old package's media, backups and render
            // cache would be mixed into this one.
            if replacesExisting {
                try await ProjectStore.trashPackage(at: url, checkingLock: true)
            }
            try ProjectStore.preparePackage(at: url)
            let lock = try lockForProject(at: url)
            // Imports are copied as they come in, so only Save As copies,
            // carrying along what the previous package holds.
            let isNewLocation = projectURL.map { !Self.isSamePackage($0, url) } ?? true
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
            let unsavedResults = analysis.unsavedResults()
            let saved = try await ProjectStore.save(
                snapshot, to: url, copying: copying,
                changeScores: unsavedResults.changeScores, references: unsavedResults.referenceData,
                thumbnails: unsavedResults.thumbnails, beats: unsavedResults.beatTracks,
                originalScores: unsavedResults.originalScoreTracks, sources: unsavedResults.sources, discardingBeats: unsavedResults.discardedBeats,
                invalidatingScores: unsavedResults.invalidatedScores, previousPackageURL: projectURL
            )
            analysis.markSaved(unsavedResults)
            analysis.dropForgottenReferences(in: saved)
            // Edits made while saving stay; only the media locations change.
            history.adoptMediaLocations(of: snapshot, from: saved)
            project.applyMediaLocations(from: saved)
            savedProject = saved
            lastAutosaved = nil
            autosaveStatus.succeeded()
            projectLock = lock
            fileMonitor.track(package: url)
            analysis.packageURL = url
            if isNewLocation { setProjectURL(url) }
            ProjectWindows.shared.remember(url)
            return true
        } catch {
            Self.showAlert(title: "Couldn't Save Project", message: ErrorAdvice.sentence(for: error))
            return false
        }
    }

    /// Writes a recovery copy into the package's `Backups/` folder. Only for
    /// projects that have been saved once (there is no package before that),
    /// and only when something changed since the last save or autosave.
    func autosave() async {
        guard let url = projectURL, hasUnsavedChanges, project != lastAutosaved else { return }
        let snapshot = project
        do {
            _ = try await PackageCoordinator.shared.run(on: [url]) {
                try ProjectStore.writeBackup(of: snapshot, in: url)
            }
            lastAutosaved = snapshot
            autosaveStatus.succeeded()
        } catch {
            NSLog("Autosave failed: \(error.localizedDescription)")
            autosaveStatus.failed(ErrorAdvice.sentence(for: error))
        }
    }

    // MARK: - Changes from outside

    /// Picks up edits made to `project.json` outside the app. With nothing
    /// unsaved the file's version replaces the project; with unsaved edits
    /// the person chooses. Either way the switch is an ordinary edit, so
    /// undo brings the previous version back.
    func checkForExternalProjectChange() {
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
                    thumbnailed: result.assetsWithThumbnails, beats: result.beats,
                    originalScores: result.originalScores, sources: result.analysisSources,
                    rejected: result.rejectedAnalysis, packageURL: url
                )
                analysis.update(with: result.project)
                replacement.reset()
                replacement.markChanged(result.changedMedia)
                replacement.markMissing(result.offlineMedia)
                reportMediaProblems(in: result)
            } catch {
                fileMonitor.acknowledge(change)
                Self.showAlert(
                    title: "The Project File Changed but Couldn't Be Read",
                    message: "\(ErrorAdvice.sentence(for: error))\n\nThe open project is unchanged. Saving will overwrite the file."
                )
            }
        }
    }

    // MARK: - Closing

    enum UnsavedChoice { case save, discard, cancel }

    /// Asks what to do with this project's unsaved changes before they
    /// would be lost; nil when there are none to ask about.
    func askAboutUnsavedChanges(_ question: String) -> UnsavedChoice? {
        guard hasUnsavedChanges, projectURL != nil else { return nil }
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

    /// Whether this project may go: unsaved changes are saved, discarded
    /// (its autosaves marked seen) or keep it open. `question` is what the
    /// person is asked.
    func settleUnsavedChanges(asking question: String) async -> Bool {
        switch askAboutUnsavedChanges(question) {
        case nil: return true
        case .save?: return await save()
        case .discard?:
            if let url = projectURL { await ProjectStore.markBackupsSeenQueued(in: url) }
            return true
        case .cancel?: return false
        }
    }

    /// The window is closing: lets go of the project's lock and watching.
    func close() {
        fileMonitor.stop()
        projectLock?.release()
        projectLock = nil
        DetectedBeats.shared.remove(owner: ObjectIdentifier(analysis))
        ProjectWindows.shared.unregister(self)
    }

    // MARK: - Helpers

    private func lockForProject(at url: URL) throws -> ProjectLock {
        if let projectLock, Self.isSamePackage(projectLock.packageURL, url) {
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

    private func askToRestore(_ backup: URL, name: String) -> Bool {
        let date = (try? backup.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let alert = NSAlert()
        alert.messageText = "Restore unsaved changes to \u{201C}\(name)\u{201D}?"
        alert.informativeText = "An automatic backup from \(date.formatted(date: .abbreviated, time: .shortened)) has changes that were never saved. Restoring them is an ordinary edit: you can undo it, and nothing is written until you save."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Don't Restore")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Tells of media that changed since the project was saved or can't be
    /// found, with buttons to check the sync or locate the files; the
    /// Clips list keeps offering both until they are dealt with.
    private func reportMediaProblems(in result: ProjectLoadResult) {
        let changed = result.changedMedia.compactMap { result.project.mediaClip(id: $0)?.name }
        let missing = result.missingMedia.map(\.lastPathComponent)
        guard !changed.isEmpty || !missing.isEmpty else { return }
        replacement.notice = MediaReplacementController.problemsNotice(changed: changed, missing: missing)
    }

    static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
