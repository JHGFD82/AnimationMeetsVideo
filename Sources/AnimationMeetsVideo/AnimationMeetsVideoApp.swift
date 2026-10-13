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
        panel.allowedContentTypes = [.folder, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose a project (.\(ProjectStore.packageExtension)) to open."
        guard panel.runModal() == .OK, let selection = panel.url else { return }
        let url = ProjectStore.packageURL(forSelection: selection)

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
            if let type = UTType(filenameExtension: ProjectStore.packageExtension, conformingTo: .package) {
                panel.allowedContentTypes = [type]
            }
            panel.nameFieldStringValue = project.name
            guard panel.runModal() == .OK, var url = panel.url else { return }
            if url.pathExtension != ProjectStore.packageExtension {
                url.appendPathExtension(ProjectStore.packageExtension)
            }
            destination = url
        }
        guard let url = destination else { return }

        Task {
            do {
                try ProjectStore.preparePackage(at: url)
                guard let copying = chooseMediaToCopy(for: project, into: url) else { return }
                project = try await ProjectStore.save(project, to: url, copying: copying)
                projectURL = url
            } catch {
                showAlert(title: "Couldn't Save Project", message: error.localizedDescription)
            }
        }
    }

    /// Picks which media to copy into the package. Same-volume copies are
    /// APFS clones that cost no space, so they happen without asking; copies
    /// that use real disk space need confirmation. Returns nil to cancel.
    private func chooseMediaToCopy(for project: EditingProject, into packageURL: URL) -> Set<UUID>? {
        let candidates = ProjectStore.mediaToCopy(in: project, into: packageURL)
        var selected = Set(candidates.filter(\.isClone).map(\.clipID))
        let heavy = candidates.filter { !$0.isClone }
        guard !heavy.isEmpty else { return selected }

        let total = heavy.reduce(Int64(0)) { $0 + $1.byteCount }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Copy \(heavy.count) media file\(heavy.count == 1 ? "" : "s") into the project?"
        alert.informativeText = "\(size) will be copied because the files are on a different volume than the project, so it uses real disk space. You can leave them where they are and the project will reference them in place."
        alert.addButton(withTitle: "Copy \(size)")
        alert.addButton(withTitle: "Reference in Place")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            selected.formUnion(heavy.map(\.clipID))
            return selected
        case .alertSecondButtonReturn:
            return selected
        default:
            return nil
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

