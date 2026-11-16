import SwiftUI

/// The Scripts menu (see docs/python-scripting.md, "A script"), for the
/// project in the front window: its scripts, listed under the first line
/// of each one's docstring, then New Script…, Show Scripts Folder, Run
/// Script File… with the last few run that way, and the Python Console.
///
/// With no Python to run them on, the items are off and the menu says
/// why.
struct ScriptCommands: Commands {
    @FocusedValue(\.projectSession) private var session
    /// `ScriptActions.recentFiles`'s stored list, for Run Script File….
    @AppStorage(Preferences.recentScriptFiles) private var recentStored = "[]"
    @AppStorage(Preferences.pythonInterpreter) private var chosenPython = ""

    private var project: ProjectSession? { session.flatMap { $0.isEmpty ? nil : $0 } }

    /// Whether there is a Python to run on; given the setting so the
    /// menu follows Settings > Scripting.
    private static func hasPython(chosen: String) -> Bool {
        PythonRuntime.interpreter() != nil
    }

    var body: some Commands {
        let hasPython = Self.hasPython(chosen: chosenPython)
        let isRunning = ScriptRunner.shared.isRunning
        CommandMenu("Scripts") {
            if !hasPython {
                Text("Python isn't available. Choose one in Settings > Scripting.")
            }
            let scripts = project?.scriptLibrary.scripts ?? []
            if scripts.isEmpty {
                Text(project == nil ? "No Project Open" : "No Scripts in This Project")
            }
            ForEach(scripts) { script in
                Button(script.title) {
                    guard let project else { return }
                    Task { await ScriptActions.run(script, in: project) }
                }
                .disabled(!hasPython || isRunning)
            }
            Divider()
            Button("New Script\u{2026}") {
                guard let project else { return }
                Task { await ScriptActions.newScript(in: project) }
            }
            .disabled(project == nil)
            Button("Show Scripts Folder") {
                if let project { ScriptActions.showFolder(of: project) }
            }
            .disabled(project == nil)
            Divider()
            Button("Run Script File\u{2026}") {
                guard let project, let url = ScriptActions.chooseFile() else { return }
                Task { await ScriptActions.runFile(url, in: project) }
            }
            .disabled(project == nil || !hasPython || isRunning)
            let recents = ScriptActions.recentFiles(recentStored)
            ForEach(recents, id: \.self) { url in
                Button(url.lastPathComponent) {
                    guard let project else { return }
                    Task { await ScriptActions.runFile(url, in: project) }
                }
                .help(url.path)
                .disabled(project == nil || !hasPython || isRunning)
            }
            Divider()
            Button("Python Console") { ScriptConsoleWindow.shared.show() }
                .keyboardShortcut("y", modifiers: [.command, .option])
        }
    }
}
