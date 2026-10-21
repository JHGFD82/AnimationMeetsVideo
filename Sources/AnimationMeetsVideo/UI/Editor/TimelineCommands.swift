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
    /// Turns the selected clips off, or on again when all are off.
    var toggleEnabled: () -> Void
    var isSnapping: Bool
    var toggleSnapping: () -> Void
    var tool: TimelineTool
    var setTool: (TimelineTool) -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var zoomToFit: () -> Void
    /// Renders what still needs it now; nil when nothing does.
    var renderNow: (() -> Void)?
    /// The timeline the actions work in, and the structure of the project
    /// (`EditingProject.structure`) as the timeline had it when it made
    /// them: what they read that may since have changed (see `==`).
    var timelineID: UUID
    var structure: EditingProject
}

extension TimelineActions: Equatable {
    /// Whether the menu would offer the same and the actions do the same:
    /// the same timeline and structure, which they act on (where clips are,
    /// the timeline's length), and the same snapping, tool and render
    /// state, which the menu shows. The playhead, selection and zoom they
    /// read as they run. A new set for every redraw would rebuild the menu
    /// bar on every step of dragging a value, which changes none of these.
    nonisolated static func == (lhs: TimelineActions, rhs: TimelineActions) -> Bool {
        lhs.timelineID == rhs.timelineID && lhs.isSnapping == rhs.isSnapping && lhs.tool == rhs.tool
            && (lhs.renderNow == nil) == (rhs.renderNow == nil) && lhs.structure == rhs.structure
    }
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
/// snapping, skimming and zoom, so they can be found and not only
/// remembered.
///
/// Most of these keys have no modifier, and a menu key equivalent without
/// one would take the key from a text field or list being typed in. The
/// timeline's own key handling (`TimelineView.handleKey`) leaves those
/// alone, so here the key is written after the name instead, as the
/// keyframe ease menu does. Split at Playhead has a modifier and is a real
/// shortcut.
struct TimelineCommands: Commands {
    @FocusedValue(\.timelineActions) private var actions
    /// The person's, not a timeline's, so they work with no timeline in
    /// front.
    @AppStorage(Preferences.timelineSkimming) private var skimming = true
    @AppStorage(Preferences.scrubAudio) private var scrubAudio = true

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
            Button("Turn Clip Off or On  V") { actions?.toggleEnabled() }
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
            Toggle("Skimming", isOn: $skimming)
            Toggle("Scrub Audio", isOn: $scrubAudio)

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
