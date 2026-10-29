import AppKit
import SwiftUI

/// SwiftPM executables have no app bundle/Info.plist, so without this the
/// process never becomes the frontmost app and its window never appears.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Nothing under a dialog hovers, skims or takes a click.
        MainActor.assumeIsolated {
            WindowInputBlock.blockUnderSheets()
            // A field starting to be edited has its whole value selected.
            FieldTextSelection.install()
        }
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
        // In the background; a project waits for it before it is read, so
        // its package effects are known.
        EffectPackageStatus.shared.installAtLaunch()
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
        // A second editor on one timeline of a project open above, from
        // the Timelines tab's Open in New Window (see `TimelineWindow`).
        WindowGroup("Timeline", id: TimelineWindow.groupID, for: TimelineWindowRef.self) { $ref in
            TimelineWindow(ref: $ref)
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
