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
    @State private var project = EditingProject.empty

    var body: some Scene {
        WindowGroup("Animation Meets Video") {
            EditorView(project: $project)
                .frame(minWidth: 1_100, minHeight: 700)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    project = EditingProject.empty
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Open Project…") {
                    openProject()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Save Project As…") {
                    saveProject()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            if let loaded = try? await ProjectStore.load(from: url) {
                project = loaded
            }
        }
    }

    private func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = project.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ProjectStore.save(project, to: url)
    }
}
