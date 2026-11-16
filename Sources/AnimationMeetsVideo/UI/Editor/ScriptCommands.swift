import SwiftUI

/// The Scripts menu (see docs/python-scripting.md, "A script"), for the
/// project in the front window.
struct ScriptCommands: Commands {
    var body: some Commands {
        CommandMenu("Scripts") {
            Button("Python Console") { ScriptConsoleWindow.shared.show() }
                .keyboardShortcut("y", modifiers: [.command, .option])
        }
    }
}
