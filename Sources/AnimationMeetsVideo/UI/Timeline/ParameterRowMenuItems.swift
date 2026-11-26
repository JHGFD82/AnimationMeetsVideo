import SwiftUI

/// Putting an effect's controls in the timeline's rows and taking them out
/// (see docs/parameter-rows.md, "Which rows a layer shows"), as menu items
/// for the effects panel's ⋯ menus and the inspector's context menus.
///
/// With a control: Show in Timeline, or Remove from Timeline while it is
/// in. Without one: Show All in Timeline for every control of the effect
/// that can be a row (or of `groupControlIDs`, an inspector group's), or
/// Remove All from Timeline while every one is in. Nothing for a control
/// that can't be a row, or outside a timeline's window (no
/// `timelineViewMemory`).
struct ParameterRowMenuItems: View {
    @Environment(\.timelineViewMemory) private var viewMemory
    let timelineID: UUID
    let clip: TimelineClip
    let effectID: UUID
    var controlID: UUID?
    /// For Show All: the controls it puts in, when not all of the effect's.
    var groupControlIDs: [UUID]?

    var body: some View {
        if let store = viewMemory?.parameterRows {
            let shown = store.rows(of: timelineID).keys(of: clip, addsKeyframed: Preferences.addsKeyframedParametersNow)
            if let controlID {
                if let key = clip.parameterKey(effect: effectID, control: controlID) {
                    if shown.contains(key) {
                        Button("Remove from Timeline") { store.change(timelineID) { $0.remove([key], from: [clip.id]) } }
                            .help("Takes this control's row out from under the clip's layer; its keyframes stay")
                    } else {
                        Button("Show in Timeline") { store.change(timelineID) { $0.show([key], on: [clip.id]) } }
                            .help("Puts this control in a row under the clip's layer, to set and keyframe it there")
                    }
                }
            } else {
                let keys = groupControlIDs.map { ids in Set(ids.compactMap { clip.parameterKey(effect: effectID, control: $0) }) }
                    ?? clip.parameterKeys(ofEffect: effectID)
                if !keys.isEmpty {
                    if keys.isSubset(of: shown) {
                        Button("Remove All from Timeline") { store.change(timelineID) { $0.remove(keys, from: [clip.id]) } }
                            .help("Takes every control of this effect out of the rows under the clip's layer; their keyframes stay")
                    } else {
                        Button("Show All in Timeline") { store.change(timelineID) { $0.show(keys, on: [clip.id]) } }
                            .help("Puts every control of this effect in rows under the clip's layer")
                    }
                }
            }
        }
    }
}

/// Where the inspector's shape groups are, for their context menus'
/// timeline rows (`ParameterRowMenuItems`): the selected clip and its
/// timeline. Nil outside a selected clip's inspector, where the rows
/// offer no menu.
struct ParameterRowMenuTarget: Equatable {
    var timelineID: UUID
    var clip: TimelineClip
}

extension EnvironmentValues {
    @Entry var parameterRowMenuTarget: ParameterRowMenuTarget?
}

extension View {
    /// A context menu with Show in Timeline for `control` of `effect`, in
    /// the inspector of a selected clip (`parameterRowMenuTarget`).
    func parameterRowMenu(effect effectID: UUID, control controlID: UUID) -> some View {
        modifier(ParameterRowContextMenu(effectID: effectID, controlID: controlID))
    }
}

private struct ParameterRowContextMenu: ViewModifier {
    @Environment(\.parameterRowMenuTarget) private var target
    let effectID: UUID
    let controlID: UUID

    func body(content: Content) -> some View {
        if let target {
            content.contextMenu {
                ParameterRowMenuItems(timelineID: target.timelineID, clip: target.clip, effectID: effectID, controlID: controlID)
            }
        } else {
            content
        }
    }
}
