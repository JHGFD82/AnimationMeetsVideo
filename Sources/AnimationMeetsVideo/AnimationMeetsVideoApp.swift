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
    @State private var projectURL: URL?

    var body: some Scene {
        WindowGroup("Animation Meets Video") {
            EditorView(project: $project)
                .frame(minWidth: 1_100, minHeight: 700)
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
            }
        }
    }

    private func newProject() {
        guard confirmDiscardingCurrentProject() else { return }
        project = EditingProject.empty
        projectURL = nil
    }

    private func openProject() {
        guard confirmDiscardingCurrentProject() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let result = try await ProjectStore.load(from: url)
                project = result.project
                projectURL = url
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
    }

    private func saveProject(forcePanel: Bool = false) {
        var destination = forcePanel ? nil : projectURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = project.name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        guard let url = destination else { return }
        do {
            try ProjectStore.save(project, to: url)
            projectURL = url
        } catch {
            showAlert(title: "Couldn't Save Project", message: error.localizedDescription)
        }
    }

    /// There's no unsaved-changes tracking yet, so replacing a project that
    /// has content always asks first.
    private func confirmDiscardingCurrentProject() -> Bool {
        let hasContent = !project.clips.isEmpty || project.timelines.count > 1
            || project.timelines.contains { !$0.layers.isEmpty }
        guard hasContent else { return true }
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

