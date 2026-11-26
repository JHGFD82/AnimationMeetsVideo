import CoreMedia
import SwiftUI

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
