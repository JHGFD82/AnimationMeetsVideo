import SwiftUI

/// The viewer's items in the View menu: Show Handles, and the zoom and
/// place of the viewer in the window that has the keys (see
/// docs/viewer-handles.md). The canvas takes the keys itself before the
/// menu (`ViewerCanvas`), so they also work on the external display and
/// ⌘= zooms in as ⌘+ does; the timeline keeps its plain =, − and \.
struct ViewerCommands: Commands {
    @FocusedValue(\.viewerActions) private var actions
    @AppStorage(Preferences.viewerHandles) private var showsHandles = false

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            // H has no modifier, so it is written after the name rather
            // than set as a menu shortcut, which would take the key from
            // a text field (see `TimelineCommands`).
            Toggle("Show Handles  H", isOn: $showsHandles)
                .help("Show handles on the clip selected in the timeline (H)")
            Button("Zoom In") { actions?.framing.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(actions == nil)
            Button("Zoom Out") { actions?.framing.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(actions == nil)
            Button("Zoom to Fit") { actions?.framing.fit() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(actions?.framing.isFit ?? true)
            Button("Center") { actions?.framing.centerFrame() }
                .keyboardShortcut("0", modifiers: [.command, .shift])
                .disabled(actions?.framing.isCentered ?? true)
            Divider()
        }
    }
}
