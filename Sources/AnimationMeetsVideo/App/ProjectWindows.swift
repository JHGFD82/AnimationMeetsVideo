import AppKit
import SwiftUI

/// Every open project window's session, for what spans them: sending a
/// project to the window that has it open (or to an empty one, or a new
/// one), remembering which projects were open so the next launch opens
/// them again, keeping the recent projects, and asking about unsaved
/// changes in each before quitting.
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
    /// list to reopen.
    private var isTerminating = false

    var sessions: [ProjectSession] { entries.compactMap(\.session) }

    func register(_ session: ProjectSession) {
        entries.removeAll { $0.session == nil }
        entries.append(Entry(session: session))
    }

    func unregister(_ session: ProjectSession) {
        entries.removeAll { $0.session == nil || $0.session === session }
        openProjectsChanged()
    }

    func session(showing url: URL) -> ProjectSession? {
        sessions.first { $0.isOpen(url) }
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

    /// Running exports are offered to keep going, then each project with
    /// unsaved changes for saving, in turn; keeping an export or
    /// cancelling a save keeps the app open.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard ExportWindow.confirmStopping(ExportWindow.runningAnywhere, because: "Quitting") else { return .terminateCancel }
        let unsaved = sessions.filter { $0.hasUnsavedChanges && $0.projectURL != nil }
        isTerminating = true
        guard !unsaved.isEmpty else { return .terminateNow }
        Task {
            for session in unsaved {
                let question = "Save changes to \u{201C}\(session.project.name)\u{201D} before quitting?"
                guard await session.settleUnsavedChanges(asking: question) else {
                    isTerminating = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
