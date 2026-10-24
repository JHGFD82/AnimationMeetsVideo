import AppKit
import SwiftUI

private struct ProjectSessionKey: FocusedValueKey { typealias Value = ProjectSession }

extension FocusedValues {
    /// The session of the editor window in front, for the File menu.
    var projectSession: ProjectSession? {
        get { self[ProjectSessionKey.self] }
        set { self[ProjectSessionKey.self] = newValue }
    }
}

/// An editor window: one project's session and its editor. The window
/// group keys windows by the project's package (`url`), so opening a
/// project that is already open brings its window forward; a window
/// opened without one shows the start sheet until a project is made or
/// chosen. The first window of a launch opens the projects open at the
/// last quit, the others in windows of their own.
struct ProjectWindow: View {
    static let groupID = "editor"

    @Binding var url: URL?
    @State private var session = ProjectSession()
    /// Set once this window has tried to open its project, so the start
    /// sheet doesn't flash up before that.
    @State private var opened = false
    /// Tells this window from the others, for which shows the effect
    /// package prompt's alerts.
    @State private var windowID = UUID()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var activeState
    @AppStorage(Preferences.recentProjects) private var recentProjectsStored = "[]"

    var body: some View {
        let session = session
        EditorView(
            project: Bindable(session.projectState).value, history: session.history, analysis: session.analysis,
            replacement: session.replacement, packageURL: session.projectURL
        )
            // The window runs again at every save; the editor follows the
            // project on its own (see `EditorView.==`).
            .equatable()
            .environment(session.projectState)
            .environment(session.autosaveStatus)
            .mediaReplacementDialogs(
                project: Bindable(session.projectState).value, controller: session.replacement,
                analysis: session.analysis, packageURL: session.projectURL
            )
            .newEffectPackagePrompt(isHost: NewEffectPackagePrompt.shared.hostWindow == windowID)
            .onExternalProjectChange { session.checkForExternalProjectChange() }
            .frame(minWidth: 1_100, minHeight: 700)
            .sheet(isPresented: Binding(get: { opened && session.isEmpty }, set: { _ in })) {
                ProjectStartView(
                    recents: RecentProjects(stored: recentProjectsStored).urls.filter { FileManager.default.fileExists(atPath: $0.path) },
                    onNew: {
                        Task {
                            if let created = await ProjectSession.createProject() { open(created) }
                        }
                    },
                    onOpen: { ProjectSession.chooseProjectToOpen().map(open) },
                    onOpenRecent: { ProjectWindows.shared.openRecent($0, from: session, openWindow: openWindow) }
                )
            }
            .background(WindowCloseGuard(shouldClose: shouldClose))
            .background(ProjectWindowTitle(projectState: session.projectState, savedProject: session.savedProject, packageURL: session.projectURL, autosaveStatus: session.autosaveStatus))
            .background(
                Color.clear.sheet(isPresented: Bindable(session).showsProjectSettings) {
                    // Read in the sheet's own view, so the window doesn't
                    // read the project.
                    ProjectSettingsSheet(project: Bindable(session.projectState).value)
                }
            )
            .focusedSceneValue(\.projectSession, session)
            // A project opened from Finder (double-click, or dropped on
            // the Dock icon) comes to a window here rather than a new empty
            // one, which then sends it on (see `ProjectWindows.open`).
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onOpenURL { opened in
                guard opened.isFileURL else { return }
                // An effect package is installed, not opened as a project.
                if opened.pathExtension == EffectPackage.fileExtension {
                    NewEffectPackagePrompt.shared.open(opened)
                    return
                }
                let package = ProjectStore.packageURL(forSelection: opened)
                if ProjectWindows.shared.launchHandled {
                    open(package)
                } else {
                    ProjectWindows.shared.openedAtLaunch = package
                }
            }
            // The effect package prompt shows on the window last in front.
            .onChange(of: activeState, initial: true) { _, state in
                if state == .key { NewEffectPackagePrompt.shared.claimHost(windowID) }
            }
            .task {
                session.onProjectURLChange = { url = $0 }
                session.autosaveStatus.save = { Task { await session.save() } }
                await openAtStart()
                opened = true
                while !Task.isCancelled {
                    try? await Task.sleep(for: ProjectSession.autosaveInterval)
                    await session.autosave()
                }
            }
            .onDisappear { session.close() }
    }

    private func open(_ package: URL) {
        ProjectWindows.shared.open(package, from: session, openWindow: openWindow)
    }

    /// The project this window was opened for; or, for the first window
    /// of a launch, what Finder asked to open, else the projects open at
    /// the last quit, the first here and the rest in windows of their own.
    private func openAtStart() async {
        if let url {
            if !(await session.open(url)) { self.url = nil }
            return
        }
        let windows = ProjectWindows.shared
        guard !windows.launchHandled else { return }
        windows.launchHandled = true
        if let requested = windows.openedAtLaunch {
            windows.openedAtLaunch = nil
            await session.open(requested)
            return
        }
        let reopen = windows.projectsToReopen()
        guard let first = reopen.first else { return }
        await session.open(first)
        for other in reopen.dropFirst() { openWindow(value: other) }
    }

    /// Unsaved changes are offered for saving before the window closes;
    /// cancelling keeps it open. The question needs the window kept on
    /// screen, so it is asked after saying no, and the window closed again
    /// once settled.
    private func shouldClose(_ window: NSWindow) -> Bool {
        guard session.hasUnsavedChanges, session.projectURL != nil, !session.closeConfirmed else { return true }
        Task {
            let question = "Save changes to \u{201C}\(session.project.name)\u{201D} before closing?"
            guard await session.settleUnsavedChanges(asking: question) else { return }
            session.closeConfirmed = true
            window.close()
        }
        return false
    }
}
