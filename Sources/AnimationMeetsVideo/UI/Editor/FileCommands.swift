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

    /// The toolbar's Export, nil while an export runs.
    var exportTimeline: FileMenuAction? {
        get { self[ExportKey.self] }
        set { self[ExportKey.self] = newValue }
    }
}

/// Import and Export in the File menu, so they can be found from the menu
/// bar and not only as the browser's + button and the toolbar's Export.
struct FileCommands: Commands {
    @FocusedValue(\.importMedia) private var importMedia
    @FocusedValue(\.exportTimeline) private var exportTimeline

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Import Media…") { importMedia?() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(importMedia == nil)
            Button("Export…") { exportTimeline?() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(exportTimeline == nil)
        }
    }
}
