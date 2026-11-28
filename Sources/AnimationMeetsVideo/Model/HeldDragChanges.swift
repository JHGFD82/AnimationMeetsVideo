import Foundation

extension TimelineClip {
    /// This clip, as it is now, with what a drag changed from `start` to
    /// `edited` applied: the effects the drag changed, added or removed,
    /// and its other settings only if the drag changed them. A drag works
    /// on its own copy of the clip from when it began, while writes from
    /// elsewhere (a script finishing during the drag) can land on the clip
    /// meanwhile; putting the whole copy back undid those
    /// (code-review-notes.md, F26).
    func applyingDrag(from start: TimelineClip, to edited: TimelineClip) -> TimelineClip {
        var result = self
        var startRest = start, editedRest = edited
        startRest.effects = []
        editedRest.effects = []
        if editedRest != startRest {
            result = edited
            result.effects = effects
        }
        for (position, effect) in edited.effects.enumerated() {
            if let before = start.effects.first(where: { $0.id == effect.id }) {
                guard before != effect, let index = result.effects.index(of: effect.id) else { continue }
                result.effects[index] = effect
            } else if result.effects.index(of: effect.id) == nil {
                result.effects.insert(effect, at: min(position, result.effects.count))
            }
        }
        for effect in start.effects where edited.effects.index(of: effect.id) == nil {
            if let index = result.effects.index(of: effect.id) { result.effects.remove(at: index) }
        }
        return result
    }
}
