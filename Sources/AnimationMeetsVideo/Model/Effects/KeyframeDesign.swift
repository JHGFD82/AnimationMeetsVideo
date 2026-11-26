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
        return effect.controls.filter { !$0.kind.isChoice && !$0.kind.isCurve && !$0.kind.isPath }
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
        // A strobe scales an opacity, a scale or a gain, and adds to the
        // rest, unless it takes over from a method that had chosen.
        if kind == .strobeKeys, current == nil, Self.strobeScales(target, in: clip) { setup.combine = .multiply }
        if kind == .beatKeys || kind == .strobeKeys, setup.beatLayer == nil, let timeline = timeline(id: timelineID) {
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
        if kind == .strobeKeys {
            effect.changeControl(.strobeLevels) { $0.number = AnimatedValue(Effect.strobeLevelsDefault(for: setup.combine)) }
            // On the beats where there are some to follow.
            if let layerID = setup.beatLayer, let layer = timeline(id: timelineID)?.layer(id: layerID),
               layerHasBeats(layer, tracks: DetectedBeats.shared.tracks) {
                effect.changeControl(.strobeTiming) { $0.choice = StrobeTiming.beats.rawValue }
            }
        }
        editClip(clipID, in: timelineID) { clip in
            clip.effects.insert(effect, at: at.clamped(between: 0, and: clip.effects.count))
        }
        regenerateKeyframes(ofEffect: effect.id, onClip: clipID, in: timelineID)
        return effect.id
    }
}

// MARK: - Strobe Keys

extension Effect {
    /// Strobe Keys' Min and Max on a new effect: a factor from nothing to
    /// all of it with Multiply, an amount with Add or a value with Replace.
    static func strobeLevelsDefault(for combine: KeyframingCombine) -> ComponentValue {
        ComponentValue(values: combine == .multiply ? [0, 1] : [0, 10])
    }

    /// Whether the Keyframe Designer lists a setting of this Keyframing
    /// effect as it is set now: Strobe Keys shows the settings of its
    /// timing and of the unit its times are in, not the others'.
    func designerShows(_ control: ControlKind) -> Bool {
        guard kind == .strobeKeys else { return true }
        let timing = choice(.strobeTiming, as: StrobeTiming.self) ?? .perSecond
        let byShare = (choice(.strobeTimes, as: StrobeTimes.self) ?? .share) == .share
        switch control {
        case .beatSelection, .strobeEvery, .beatDivision, .beatShift: return timing == .beats
        case .strobeFrames: return timing == .frames
        case .strobeRate: return timing == .perSecond
        case .frameShift: return timing != .beats
        // Accents fall on downbeats and on a pattern's accented steps.
        case .accent: return timing == .beats || StrobeStep.steps(of: keyframing?.pattern ?? "").contains(.accent)
        case .attackShare, .decayShare, .sustainForShare, .releaseShare: return byShare
        case .attackFrames, .decayFrames, .sustainForFrames, .releaseFrames: return !byShare
        default: return true
        }
    }

    /// Sets how a Strobe Keys effect meets its target, and its Min and Max
    /// to the new mode's defaults when they were the old one's, since
    /// they mean values, amounts or factors as it says.
    mutating func setStrobeCombine(_ combine: KeyframingCombine) {
        guard let old = keyframing?.combine, old != combine else { return }
        keyframing?.combine = combine
        changeControl(.strobeLevels) { levels in
            guard !levels.isAnimated, levels.number.value == Self.strobeLevelsDefault(for: old) else { return }
            levels.number = AnimatedValue(Self.strobeLevelsDefault(for: combine))
        }
    }

    /// Exchanges Strobe Keys' Min and Max, at every keyframe, so the
    /// control dips on each pulse rather than rising.
    mutating func swapStrobeLevels() {
        changeControl(.strobeLevels) { $0.number = $0.number.swappingFirstTwoComponents() }
    }

    /// Whether Strobe Keys timed per second puts its pulses between frames
    /// `frame` seconds long, so how long each is seen for varies: its rate
    /// isn't a whole number of frames, or it changes.
    func strobeFallsBetweenFrames(frame: Double) -> Bool {
        guard kind == .strobeKeys, (choice(.strobeTiming, as: StrobeTiming.self) ?? .perSecond) == .perSecond,
              let rate = control(.strobeRate), rate.enabled, frame > 0
        else { return false }
        if rate.isAnimated { return true }
        guard let perSecond = rate.number.value.values.first, perSecond > 0 else { return false }
        let frames = 1 / (perSecond * frame)
        return abs(frames - frames.rounded()) > 1e-6
    }

    /// Strobe Keys' Duty preset: no attack, decay or release, held at the
    /// peak for half of each interval, a share so it follows the tempo.
    mutating func applyStrobeDuty() {
        changeControl(.strobeTimes) { $0.choice = StrobeTimes.share.rawValue }
        let duty: [(ControlKind, Double)] = [(.attackShare, 0), (.decayShare, 0), (.releaseShare, 0), (.sustainLevel, 100), (.sustainForShare, 50)]
        for (kind, value) in duty {
            changeControl(kind) { $0.number = AnimatedValue(ComponentValue(values: [value])) }
        }
    }
}

extension AnimatedValue where Value == ComponentValue {
    /// The same with its first two components exchanged, in its value and
    /// at every keyframe.
    func swappingFirstTwoComponents() -> AnimatedValue {
        func swapped(_ value: ComponentValue) -> ComponentValue {
            var values = value.values
            if values.count >= 2 { values.swapAt(0, 1) }
            return ComponentValue(values: values)
        }
        return AnimatedValue(swapped(value), keyframes: keyframes.map { $0.with(value: swapped($0.value)) })
    }
}
