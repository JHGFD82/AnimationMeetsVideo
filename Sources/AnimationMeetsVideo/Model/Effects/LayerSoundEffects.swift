import Foundation

/// Sound effects on Sound and Music layers (see docs/audio.md, "Sound
/// effects"): a stack everything on the layer plays through, after each
/// clip's own effects, volume and pan and before the layer's volume and
/// pan. Its keyframes count in the timeline's time, as the layer's volume
/// does.
extension EditingProject {
    /// Applies `change` to a layer's sound effects.
    mutating func editLayerEffects(of layerID: UUID, in timelineID: UUID, _ change: (inout [Effect]) -> Void) {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let lIndex = timelines[tIndex].layers.firstIndex(id: layerID)
        else { return }
        change(&timelines[tIndex].layers[lIndex].audioEffects)
    }

    /// Adds a new sound effect of `kind` at the end of a Sound or Music
    /// layer's stack, named for it. Returns its ID; nil for a picture
    /// effect or a video layer.
    @discardableResult
    mutating func addEffect(_ kind: EffectKind, toLayer layerID: UUID, in timelineID: UUID) -> UUID? {
        guard kind.isAudio, let layer = timeline(id: timelineID)?.layer(id: layerID), layer.kind.isAudio else { return nil }
        let effect = Effect.make(kind, among: layer.audioEffects)
        editLayerEffects(of: layerID, in: timelineID) { $0.append(effect) }
        return effect.id
    }

    /// Applies `change` to one of a layer's sound effects.
    mutating func editEffect(_ effectID: UUID, ofLayer layerID: UUID, in timelineID: UUID, _ change: (inout Effect) -> Void) {
        editLayerEffects(of: layerID, in: timelineID) { effects in
            if let index = effects.index(of: effectID) { change(&effects[index]) }
        }
    }

    mutating func removeEffect(_ effectID: UUID, fromLayer layerID: UUID, in timelineID: UUID) {
        editLayerEffects(of: layerID, in: timelineID) { $0.removeAll { $0.id == effectID } }
    }

    /// Moves one of a layer's sound effects to `index` (0 is the top, the
    /// first the sound plays through).
    mutating func moveEffect(_ effectID: UUID, ofLayer layerID: UUID, in timelineID: UUID, toIndex index: Int) {
        editLayerEffects(of: layerID, in: timelineID) { effects in
            guard let from = effects.index(of: effectID) else { return }
            let effect = effects.remove(at: from)
            effects.insert(effect, clampedAt: index)
        }
    }
}
