import AppKit
import SwiftUI

/// The File menu's project items, for the window in front: a new project
/// or one opened goes to that window while its start sheet is up, and to
/// a window of its own otherwise; one already open brings its window
/// forward (see `ProjectWindows.open`).
struct ProjectCommands: Commands {
    @FocusedValue(\.projectSession) private var session
    @Environment(\.openWindow) private var openWindow
    /// `RecentProjects.stored`, for Open Recent.
    @AppStorage(Preferences.recentProjects) private var recentProjectsStored = "[]"

    private var recents: RecentProjects { RecentProjects(stored: recentProjectsStored) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") {
                Task {
                    guard let url = await ProjectSession.createProject() else { return }
                    ProjectWindows.shared.open(url, from: session, openWindow: openWindow)
                }
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Open Project…") {
                guard let url = ProjectSession.chooseProjectToOpen() else { return }
                ProjectWindows.shared.open(url, from: session, openWindow: openWindow)
            }
            .keyboardShortcut("o", modifiers: [.command])

            Menu("Open Recent") {
                ForEach(recents.urls, id: \.self) { url in
                    Button(RecentProjects.name(of: url)) {
                        ProjectWindows.shared.openRecent(url, from: session, openWindow: openWindow)
                    }
                    .help(RecentProjects.location(of: url))
                }
                Divider()
                Button("Clear Menu") {
                    recentProjectsStored = RecentProjects().stored
                    NSDocumentController.shared.clearRecentDocuments(nil)
                }
                .disabled(recents.paths.isEmpty)
            }

            Button("Open Backup…") {
                guard let url = session?.chooseBackupToOpen() else { return }
                ProjectWindows.shared.open(url, from: session, openWindow: openWindow)
            }
            .disabled(session?.isEmpty ?? true)

            Divider()

            Button("Save Project") {
                Task { await session?.save() }
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(session?.isEmpty ?? true)

            Button("Save Project As…") {
                Task { await session?.save(forcePanel: true) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(session?.isEmpty ?? true)

            Divider()

            Button("Project Settings…") {
                session?.showsProjectSettings = true
            }
            .keyboardShortcut("j", modifiers: [.command])
            .disabled(session?.isEmpty ?? true)

            Divider()

            Button("New Effect Package…") {
                NewEffectPackagePrompt.shared.ask()
            }
        }
    }
}
