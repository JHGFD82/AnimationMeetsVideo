import Foundation

// The Keyframe Designer (see docs/keyframing-effects.md) works from the
// control being driven rather than from the Keyframing effect: it picks
// a control, then the method that writes its keyframes. These are the
// model's side of that: which effect drives a control, and changing the
// method, which swaps the effect for one of another kind.

extension EditingProject {
    /// The controls of an effect the designer can drive: its numeric ones,
    /// not choices or curves. A Keyframing effect's own settings aren't
    /// offered: it drives, it isn't driven.
    static func designableControls(of effect: Effect) -> [EffectControl] {
        guard !effect.kind.isKeyframing, effect.missing == nil else { return [] }
        return effect.controls.filter { !$0.kind.isChoice && !$0.kind.isCurve }
    }

    /// The Keyframing effect that writes to `target` on a clip: the top one
    /// when, unusually, several do.
    func keyframingEffect(driving target: KeyframingTarget, in clip: TimelineClip) -> Effect? {
        clip.effects.first { $0.kind.isKeyframing && $0.keyframing?.target == target }
    }

    /// Sets how `target` is driven, as one change: `kind` nil takes away the
    /// Keyframing effect driving it, putting the target back as it was; a
    /// kind replaces it with one of that kind, which keeps its component,
    /// combine, range, beats and sound, and starts again from the target as
    /// it was before. A new one goes just above the effect holding the
    /// target, so it can reach it (at the top for the clip's volume or a
    /// sound effect's control). Returns the effect driving it now; nil when
    /// none does, or the clip has no picture stack to hold one.
    @discardableResult
    mutating func setKeyframing(
        _ kind: EffectKind?, driving target: KeyframingTarget, onClip clipID: UUID, in timelineID: UUID
    ) -> UUID? {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip, clip.number(of: target) != nil else { return nil }
        let current = keyframingEffect(driving: target, in: clip)
        if current?.kind == kind { return current?.id }
        var setup = KeyframingSetup()
        var index: Int?
        if let current {
            index = clip.effects.index(of: current.id)
            if let old = current.keyframing {
                setup.component = old.component
                setup.combine = old.combine
                setup.range = old.range
                setup.beatLayer = old.beatLayer
                setup.audioSource = old.audioSource
            }
            removeEffect(current.id, fromClip: clipID, in: timelineID)
        }
        guard let kind else { return nil }
        guard kind.isKeyframing, hasEffectStack(clip) else { return nil }
        setup.target = target
        if kind == .audioKeys, setup.audioSource == nil { setup.audioSource = .mix }
        if kind == .beatKeys, setup.beatLayer == nil, let timeline = timeline(id: timelineID) {
            // The first Sound or Music layer with beats, else the first.
            let layers = timeline.layers.filter(\.kind.isAudio)
            setup.beatLayer = (layers.first { layerHasBeats($0, tracks: DetectedBeats.shared.tracks) } ?? layers.first)?.id
        }
        guard let after = clipAndLayer(clipID, in: timelineID)?.clip else { return nil }
        let at: Int
        if let index {
            at = index
        } else if case .control(let effectID, _) = target, let holder = after.effects.index(of: effectID) {
            at = holder
        } else {
            at = 0
        }
        var effect = Effect.make(kind, among: after.effects)
        effect.keyframing = setup
        editClip(clipID, in: timelineID) { clip in
            clip.effects.insert(effect, at: at.clamped(between: 0, and: clip.effects.count))
        }
        regenerateKeyframes(ofEffect: effect.id, onClip: clipID, in: timelineID)
        return effect.id
    }
}
