import SwiftUI

// Putting an effect's controls in the timeline's rows and taking them
// out, from its ⋯ menus (see docs/parameter-rows.md, "Which rows a layer
// shows").
extension EffectsPanel {
    /// Whether `key` is in `clip`'s rows now.
    private func isInTimeline(_ key: ParameterRowKey, of clip: TimelineClip) -> Bool {
        guard let store = viewMemory?.parameterRows else { return false }
        return store.rows(of: timelineID).keys(of: clip, addsKeyframed: Preferences.addsKeyframedParametersNow).contains(key)
    }

    /// Show in Timeline, or Remove from Timeline while it is in, for a
    /// control that can be a row.
    @ViewBuilder
    func timelineRowItem(_ control: EffectControl, of effect: Effect, in clip: TimelineClip) -> some View {
        if let store = viewMemory?.parameterRows, let key = clip.parameterKey(effect: effect.id, control: control.id) {
            if isInTimeline(key, of: clip) {
                Button("Remove from Timeline") { store.change(timelineID) { $0.remove([key], from: [clip.id]) } }
                    .help("Takes this control's row out from under the clip's layer; its keyframes stay")
            } else {
                Button("Show in Timeline") { store.change(timelineID) { $0.show([key], on: [clip.id]) } }
                    .help("Puts this control in a row under the clip's layer, to set and keyframe it there")
            }
        }
    }

    /// Show All in Timeline, or Remove All from Timeline while every one
    /// of the effect's controls is in.
    @ViewBuilder
    func timelineRowsItem(_ effect: Effect, in clip: TimelineClip) -> some View {
        let keys = clip.parameterKeys(ofEffect: effect.id)
        if let store = viewMemory?.parameterRows, !keys.isEmpty {
            if keys.allSatisfy({ isInTimeline($0, of: clip) }) {
                Button("Remove All from Timeline") { store.change(timelineID) { $0.remove(keys, from: [clip.id]) } }
            } else {
                Button("Show All in Timeline") { store.change(timelineID) { $0.show(keys, on: [clip.id]) } }
                    .help("Puts every control of this effect in rows under the clip's layer")
            }
        }
    }
}
