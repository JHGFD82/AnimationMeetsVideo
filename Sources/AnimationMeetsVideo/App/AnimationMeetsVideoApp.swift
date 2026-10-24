import AppKit
import SwiftUI

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

    /// Each open project's unsaved changes are offered for saving first
    /// (see `ProjectWindows.shouldTerminate`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { ProjectWindows.shared.shouldTerminate() }
    }
}

@main
struct AnimationMeetsVideoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Before any project is read, so its package effects are known.
        EffectPackageStore.installAtLaunch()
        // The projects open at the last quit are opened again by the first
        // window (`ProjectWindows.projectsToReopen`). Windows the system
        // restored as well would race it for the same projects, so its
        // restoration is off for this app only.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    var body: some Scene {
        // One window per open project, keyed by its package, so several
        // projects can be open at once (see `ProjectWindow`).
        WindowGroup("Animation Meets Video", id: ProjectWindow.groupID, for: URL.self) { $url in
            ProjectWindow(url: $url)
        }
        .windowResizability(.contentSize)
        .commands {
            ProjectCommands()
            FileCommands()
            EditCommands()
            TimelineCommands()
            WindowCommands()
        }

        // Help > Keyboard Shortcuts (⌘/).
        Window("Keyboard Shortcuts", id: KeyboardShortcutsView.windowID) {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentMinSize)

        // App > Settings… (⌘,): how the editor behaves for every project.
        Settings {
            SettingsView()
        }
    }
}
