import AppKit
import SwiftUI

/// Every open project window's session, for what spans them: sending a
/// project to the window that has it open (or to an empty one, or a new
/// one), remembering which projects were open so the next launch opens
/// them again, keeping the recent projects, asking about unsaved changes
/// in each before quitting, and putting the start sheet back up when the
/// last editor window closes rather than quitting.
@MainActor
final class ProjectWindows {
    static let shared = ProjectWindows()

    private struct Entry {
        weak var session: ProjectSession?
    }

    private var entries: [Entry] = []
    /// Set once the first window has handled launch: reopened the projects
    /// open at the last quit, or what Finder asked to open.
    var launchHandled = false
    /// A project Finder asked to open before launch was handled.
    var openedAtLaunch: URL?
    /// While quitting, windows closing don't take their projects off the
    /// list to reopen, and the last one closing opens no start window.
    private var isTerminating = false

    /// Opens editor windows from outside one: kept from the windows as
    /// they appear, so the app can open a start window once the last one
    /// has gone, or when its Dock icon is clicked with none open.
    var openWindow: OpenWindowAction?

    var sessions: [ProjectSession] { entries.compactMap(\.session) }

    func register(_ session: ProjectSession) {
        entries.removeAll { $0.session == nil }
        entries.append(Entry(session: session))
    }

    func unregister(_ session: ProjectSession) {
        entries.removeAll { $0.session == nil || $0.session === session }
        openProjectsChanged()
        if sessions.isEmpty { openStartWindowSoon() }
    }

    // MARK: - The start window

    /// The last editor window has closed: the app stays open and shows the
    /// start sheet in a new window, as Final Cut Pro and Logic Pro go back
    /// to their project choosers, rather than quitting. Not while quitting.
    /// Once the closing window is gone, and only if nothing has opened
    /// another meanwhile.
    private func openStartWindowSoon() {
        guard !isTerminating else { return }
        Task { @MainActor in
            guard sessions.isEmpty, !isTerminating else { return }
            openStartWindow()
        }
    }

    /// Opens an editor window with no project, which shows the start sheet.
    func openStartWindow() {
        guard let openWindow else { return }
        openWindow(id: ProjectWindow.groupID)
    }

    /// Whether an editor window is open, empty or not, for the Dock icon.
    var hasEditorWindow: Bool { !sessions.isEmpty }

    func session(showing url: URL) -> ProjectSession? {
        sessions.first { $0.isOpen(url) }
    }

    /// The project something acting on the window in front works on, such
    /// as a Python Console line.
    enum FrontProject {
        case project(ProjectSession)
        /// No project is open.
        case none
        /// Projects are open, but the window in front is none of theirs.
        case unclear
    }

    /// The project whose window, its own or a timeline window, is
    /// `mainWindow`; with one project open, that one whatever is in front.
    /// Never another open project in place of the one in front
    /// (code-review-notes.md, F35: with a timeline window in front, the
    /// console ran on whichever project opened first).
    static func frontProject(among sessions: [ProjectSession], mainWindow: NSWindow?) -> FrontProject {
        let open = sessions.filter { !$0.isEmpty }
        if let mainWindow, let session = open.first(where: { $0.owns(mainWindow) }) {
            return .project(session)
        }
        switch open.count {
        case 0: return .none
        case 1: return .project(open[0])
        default: return .unclear
        }
    }

    /// `frontProject(among:mainWindow:)` for the open projects and the
    /// app's main window.
    var frontProject: FrontProject {
        Self.frontProject(among: sessions, mainWindow: NSApp.mainWindow)
    }

    // MARK: - Routing

    /// Opens the project at `url`: brings forward the window that has it,
    /// or opens it in `session` when that is empty (its start sheet is
    /// up), or in a new window.
    func open(_ url: URL, from session: ProjectSession?, openWindow: OpenWindowAction) {
        // A backup opens as a new project made from it, never as itself.
        if url.pathExtension == ProjectBackups.fileExtension {
            guard let restored = restore(url) else { return }
            return open(restored, from: session, openWindow: openWindow)
        }
        if self.session(showing: url) != nil {
            // The window group shows one window per project, and brings
            // that one forward.
            openWindow(value: url)
        } else if let session, session.isEmpty {
            Task { await session.open(url) }
        } else {
            openWindow(value: url)
        }
    }

    /// Opens a project from Open Recent or the start sheet. One that has
    /// moved or gone is explained and taken off the list, rather than
    /// failing as a damaged project would.
    func openRecent(_ url: URL, from session: ProjectSession?, openWindow: OpenWindowAction) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            var recents = RecentProjects(stored: UserDefaults.standard.string(forKey: Preferences.recentProjects) ?? "[]")
            recents.remove(url)
            UserDefaults.standard.set(recents.stored, forKey: Preferences.recentProjects)
            ProjectSession.showAlert(
                title: "\u{201C}\(RecentProjects.name(of: url))\u{201D} Can't Be Found",
                message: "It was in \(RecentProjects.location(of: url)), but it may have been moved, renamed or deleted. It has been taken off the list of recent projects. Use Open Project… to find it."
            )
            return
        }
        open(url, from: session, openWindow: openWindow)
    }

    /// Makes a backup a new project beside the one it was taken of
    /// ("Name from backup 2026-10-24 14.30"), so opening it never touches
    /// the original; where that folder is gone, asks where. Returns the
    /// new project's package, or nil when cancelled or it failed.
    private func restore(_ backup: URL) -> URL? {
        do {
            let info = try ProjectBackups.readInfo(of: backup)
            guard let folder = ProjectBackups.defaultRestoreFolder(for: info) ?? askWhereToRestore(info) else { return nil }
            return try ProjectBackups.restore(backup, into: folder)
        } catch {
            ProjectSession.showAlert(title: "Couldn't Open Backup", message: ErrorAdvice.sentence(for: error))
            return nil
        }
    }

    private func askWhereToRestore(_ info: ProjectBackups.Info) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Restore Here"
        panel.message = "The folder \u{201C}\(info.projectName)\u{201D} was in isn't there any more. Choose where to put \u{201C}\(ProjectBackups.restoredName(for: info))\u{201D}."
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Remembering

    /// First in Open Recent (and the Dock icon's menu).
    func remember(_ url: URL) {
        var recents = RecentProjects(stored: UserDefaults.standard.string(forKey: Preferences.recentProjects) ?? "[]")
        recents.add(url)
        UserDefaults.standard.set(recents.stored, forKey: Preferences.recentProjects)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Notes which projects are open, for the next launch to open again.
    func openProjectsChanged() {
        guard !isTerminating else { return }
        let paths = sessions.compactMap { $0.projectURL?.path }
        UserDefaults.standard.set(RecentProjects(paths: paths).stored, forKey: Preferences.openProjects)
    }

    /// The projects open when the app last quit that are still there.
    func projectsToReopen() -> [URL] {
        let stored = UserDefaults.standard.string(forKey: Preferences.openProjects)
        // Before several windows, only the last project was remembered.
        let paths = stored.map { RecentProjects(stored: $0).paths }
            ?? UserDefaults.standard.string(forKey: Self.lastProjectKey).map { [$0] } ?? []
        return paths
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { (try? ProjectStore.validatePackage(at: $0)) != nil }
    }

    private static let lastProjectKey = "lastProjectPath"

    // MARK: - Quitting

    /// Running exports are offered to keep going, then open draft panels
    /// ask about their changes, then each project with unsaved changes
    /// for saving, in turn; keeping an export, Keep Editing or cancelling
    /// a save keeps the app open. Exports are asked about first, but stop
    /// only once the draft panels and save questions have let the app
    /// quit, so a Keep Editing or Cancel keeps them and their queue
    /// running; quitting waits for them to delete their partial files.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard ExportWindow.confirmStopping(ExportWindow.runningAnywhere, because: "Quitting") else { return .terminateCancel }
        // Beat Match and the motion designer ask about their drafts first.
        guard DraftPanelPresentation.confirmQuitting() else { return .terminateCancel }
        // Windows aren't sure to close on the way out.
        for session in sessions { session.viewMemory.save(for: session.project) }
        let unsaved = sessions.filter { $0.hasUnsavedChanges && $0.projectURL != nil }
        isTerminating = true
        guard !unsaved.isEmpty else {
            guard ExportWindow.anyUnderWay else { return .terminateNow }
            Task {
                await ExportWindow.stopEverythingAndWait()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        Task {
            for session in unsaved {
                let question = "Save changes to \u{201C}\(session.project.name)\u{201D} before quitting?"
                guard await session.settleUnsavedChanges(asking: question) else {
                    isTerminating = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            await ExportWindow.stopEverythingAndWait()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
