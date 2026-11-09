import SwiftUI

/// Runs a File menu command in the editor on screen. Always equal to
/// another, as `TapeScrubberOpener` is: the editor makes a new one each
/// redraw, doing the same, and a value that differed every time would
/// rebuild the menu bar on every edit. Nil disables the command.
struct FileMenuAction: Equatable {
    let run: () -> Void

    func callAsFunction() { run() }

    static func == (lhs: FileMenuAction, rhs: FileMenuAction) -> Bool { true }
}

private struct ImportMediaKey: FocusedValueKey { typealias Value = FileMenuAction }
private struct ExportKey: FocusedValueKey { typealias Value = FileMenuAction }

extension FocusedValues {
    /// The browser's Import…, which it publishes with `focusedSceneValue`.
    var importMedia: FileMenuAction? {
        get { self[ImportMediaKey.self] }
        set { self[ImportMediaKey.self] = newValue }
    }

    /// The toolbar's Export…, which opens the Export window.
    var exportTimeline: FileMenuAction? {
        get { self[ExportKey.self] }
        set { self[ExportKey.self] = newValue }
    }
}

/// Import and Export in the File menu, so they can be found from the menu
/// bar and not only as the browser's + button and the toolbar's Export.
///
/// Only with a project open: the editor under the start sheet publishes
/// them too, and media imported there would go into the empty project the
/// one opened next replaces.
struct FileCommands: Commands {
    @FocusedValue(\.importMedia) private var importMedia
    @FocusedValue(\.exportTimeline) private var exportTimeline
    @FocusedValue(\.projectSession) private var session

    private var hasProject: Bool { session.map { !$0.isEmpty } ?? false }

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Import Media…") { if hasProject { importMedia?() } }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(importMedia == nil || !hasProject)
            Button("Export…") { if hasProject { exportTimeline?() } }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(exportTimeline == nil || !hasProject)
        }
    }
}
