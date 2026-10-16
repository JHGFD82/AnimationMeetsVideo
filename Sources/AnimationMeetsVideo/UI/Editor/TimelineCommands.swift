import SwiftUI

/// What the Timeline menu can do in the timeline on screen, which publishes
/// it with `focusedSceneValue`. Nil while no timeline is shown, which
/// disables the menu.
struct TimelineActions {
    var togglePlayback: () -> Void
    /// Moves the playhead a number of frames, back when negative.
    var step: (Int) -> Void
    var goToStart: () -> Void
    var goToEnd: () -> Void
    var previousEdit: () -> Void
    var nextEdit: () -> Void
    var splitAtPlayhead: () -> Void
    /// Moves the selected clip a number of frames, earlier when negative.
    var nudge: (Int) -> Void
    var deleteSelection: () -> Void
    var isSnapping: Bool
    var toggleSnapping: () -> Void
    var tool: TimelineTool
    var setTool: (TimelineTool) -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var zoomToFit: () -> Void
    /// Renders what still needs it now; nil when nothing does.
    var renderNow: (() -> Void)?
}

private struct TimelineActionsKey: FocusedValueKey {
    typealias Value = TimelineActions
}

extension FocusedValues {
    var timelineActions: TimelineActions? {
        get { self[TimelineActionsKey.self] }
        set { self[TimelineActionsKey.self] = newValue }
    }
}

/// The Timeline menu: playback, moving the playhead, splitting, tools,
/// snapping and zoom, so they can be found and not only remembered.
///
/// Most of these keys have no modifier, and a menu key equivalent without
/// one would take the key from a text field or list being typed in. The
/// timeline's own key handling (`TimelineView.handleKey`) leaves those
/// alone, so here the key is written after the name instead, as the
/// keyframe ease menu does. Split at Playhead has a modifier and is a real
/// shortcut.
struct TimelineCommands: Commands {
    @FocusedValue(\.timelineActions) private var actions

    var body: some Commands {
        CommandMenu("Timeline") {
            Button("Play/Pause  Space") { actions?.togglePlayback() }
                .disabled(actions == nil)

            Divider()

            Button("Back One Frame  ←") { actions?.step(-1) }
                .disabled(actions == nil)
            Button("Forward One Frame  →") { actions?.step(1) }
                .disabled(actions == nil)
            Button("Back Ten Frames  ⇧←") { actions?.step(-10) }
                .disabled(actions == nil)
            Button("Forward Ten Frames  ⇧→") { actions?.step(10) }
                .disabled(actions == nil)
            Button("Previous Edit  ↑") { actions?.previousEdit() }
                .disabled(actions == nil)
            Button("Next Edit  ↓") { actions?.nextEdit() }
                .disabled(actions == nil)
            Button("Go to Start  Home") { actions?.goToStart() }
                .disabled(actions == nil)
            Button("Go to End  End") { actions?.goToEnd() }
                .disabled(actions == nil)

            Divider()

            Button("Split at Playhead") { actions?.splitAtPlayhead() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(actions == nil)
            Button("Nudge Clip Earlier  ,") { actions?.nudge(-1) }
                .disabled(actions == nil)
            Button("Nudge Clip Later  .") { actions?.nudge(1) }
                .disabled(actions == nil)
            Button("Delete Selection  ⌫") { actions?.deleteSelection() }
                .disabled(actions == nil)

            Divider()

            Picker("Tool", selection: Binding(
                get: { actions?.tool ?? .arrow },
                set: { actions?.setTool($0) }
            )) {
                ForEach(TimelineTool.allCases) { tool in
                    Text("\(tool.name)  \(String(tool.shortcutKey).uppercased())").tag(tool)
                }
            }
            .disabled(actions == nil)
            Toggle("Snapping  N", isOn: Binding(
                get: { actions?.isSnapping ?? false },
                set: { _ in actions?.toggleSnapping() }
            ))
            .disabled(actions == nil)

            Divider()

            Button("Zoom In  =") { actions?.zoomIn() }
                .disabled(actions == nil)
            Button("Zoom Out  −") { actions?.zoomOut() }
                .disabled(actions == nil)
            Button("Zoom to Fit  \\") { actions?.zoomToFit() }
                .disabled(actions == nil)

            Divider()

            Button("Render Now") { actions?.renderNow?() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(actions?.renderNow == nil)
        }
    }
}
