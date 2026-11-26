import CoreMedia
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

// Copying keyframes picked in the lanes, and pasting them at the playhead
// (see docs/parameter-rows.md, "Copying keyframes").
extension EffectsPanel {
    /// Copies the keyframes picked on `clip`'s controls. False with none.
    @discardableResult
    func copyPickedKeyframes(of clip: TimelineClip) -> Bool {
        var picked: [UUID: [UUID: [CMTime]]] = [:]
        for key in state.keyframes.picked.items {
            guard case .control(_, let clipID, let effectID, let controlID) = key.lane.parameter, clipID == clip.id else { continue }
            picked[effectID, default: [:]][controlID, default: []].append(key.time)
        }
        guard let copied = project.copiedKeyframes(picked, ofClip: clip.id, in: timelineID) else { return false }
        EditorClipboard.shared.copy(keyframes: copied)
        AccessibilityNotification.Announcement("Copied \(copied.count) keyframe\(copied.count == 1 ? "" : "s")").post()
        return true
    }

    /// Pastes the keyframes copied last at the playhead: onto the selected
    /// control when one lane was copied and a control is selected, else
    /// onto the same controls of `clip`. False with none copied.
    @discardableResult
    func pasteCopiedKeyframes(on clip: TimelineClip) -> Bool {
        guard let copied = EditorClipboard.shared.keyframes else { return false }
        let onto = state.selectedEffectID.flatMap { effectID in state.selectedControlID.map { (effectID: effectID, controlID: $0) } }
        let time = playheadTime
        let pasted = project.pasteKeyframes(copied, onClip: clip.id, in: timelineID, at: time, onto: onto)
        if pasted == 0 {
            RefusalNotice.shared.tell("None of the copied keyframes' controls is on this clip, or has as many numbers.")
        }
        return true
    }
}
