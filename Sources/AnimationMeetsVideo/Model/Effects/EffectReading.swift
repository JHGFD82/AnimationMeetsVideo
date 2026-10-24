import CoreMedia
import Foundation

/// What the effects panel tells the person about a stack beyond its values:
/// which steps do nothing, and why. See docs/effects.md, "Reading the stack".
struct EffectNote: Equatable {
    var text: String
    /// Whether the effect does nothing because of it, so it is dimmed.
    /// Otherwise the note only says how it works.
    var dims: Bool
}

extension EditingProject {
    /// Whether the clip is a nested timeline that passes through.
    func passesThrough(_ clip: TimelineClip) -> Bool {
        if case .timeline = clip.source { return clip.passThrough }
        return false
    }

    /// Whether `timelineID` is placed in another timeline, where it is
    /// drawn as a closed group.
    func isNested(_ timelineID: UUID) -> Bool {
        timelines.contains { timeline in
            timeline.layers.contains { layer in
                layer.clips.contains { clip in
                    if case .timeline(let id) = clip.source { return id == timelineID }
                    return false
                }
            }
        }
    }

    /// Whether any layer below `layer` in `timeline` has pictures, so a
    /// clip on `layer` has something under it to blend with.
    func hasPicturesBelow(_ layer: UUID, in timeline: Timeline) -> Bool {
        guard let index = timeline.layers.firstIndex(where: { $0.id == layer }) else { return false }
        return timeline.layers[(index + 1)...].contains { below in below.clips.contains { playsVideo($0) } }
    }

    /// A note on the effect at `index` in a clip's stack when it does
    /// nothing, or doesn't work as its name suggests:
    ///
    /// - a Blending step against an effect that is gone, or has been moved
    ///   below it;
    /// - a Blending step on the bottom clip of a nested timeline, which has
    ///   nothing under it to blend with;
    /// - a step a pass-through nested clip can't apply, since it needs one
    ///   combined picture, and an Opacity that is applied to each layer
    ///   inside instead.
    ///
    /// Nil for an effect with nothing to say. A step that is off or at its
    /// defaults is dimmed without a note (see `Effect.isNoOp`).
    func note(forEffectAt index: Int, in clip: TimelineClip, on layer: TimelineLayer, of timeline: Timeline) -> EffectNote? {
        guard clip.effects.indices.contains(index) else { return nil }
        let effect = clip.effects[index]
        // Said even while it is off, as it explains what the effect is.
        if let missing = effect.missing { return EffectNote(text: missing.explanation, dims: true) }
        guard effect.enabled else { return nil }
        if let package = effect.kind.definition.package, let problem = PackageKernels.knownProblem(for: package) {
            return EffectNote(text: "Its kernel doesn't compile, so it leaves the picture as it is. \(problem)", dims: true)
        }

        if effect.kind.isKeyframing { return keyframingNote(for: effect, in: clip) }
        if reachesNothing(clip, on: layer, in: timeline) {
            return EffectNote(text: "The layer this adjustment reaches down to is above it, so it reaches nothing.", dims: true)
        }
        if passesThrough(clip), effect.kind != .transform {
            return EffectNote(text: "Pass Through can't apply this: it needs one combined picture.", dims: true)
        }
        if let package = effect.kind.definition.package, !package.pictures.isEmpty {
            // A package's look reading pictures besides its own (Displace).
            if effect.against != nil, package.readsAgainst, !clip.effects.againstIsReachable(at: index) {
                return EffectNote(text: "The step it reads (Against) is gone or below this one, so it does nothing until pointed elsewhere.", dims: true)
            }
            if let input = effect.input, package.takesInput, isMissing(input) {
                return EffectNote(text: "The picture it takes is missing, so the clip is left as it is until it is found or replaced.", dims: true)
            }
            if effect.isNoOp {
                let how = switch (package.takesInput, package.readsAgainst) {
                case (true, true): "Drop a picture from the browser onto it, or set Against to an earlier step,"
                case (true, false): "Drop a picture from the browser onto it"
                default: "Set Against to an earlier step"
                }
                return EffectNote(text: "\(how) for the picture it reads.", dims: true)
            }
        } else if effect.kind.takesInput {
            guard let input = effect.input else {
                return EffectNote(text: "Drop a picture from the browser onto this effect to cut the clip with.", dims: true)
            }
            if isMissing(input) {
                return EffectNote(text: "The picture it takes is missing, so the clip is left as it is until it is found or replaced.", dims: true)
            }
        }
        if effect.kind == .stroke, !Self.strokeHasShapes(clip.effects, at: index) {
            return EffectNote(text: "A Stroke outlines the shapes above it in the stack, and none reach it: there are none, or a Matte or Blending step comes between.", dims: true)
        }
        if effect.kind == .blending {
            if !clip.effects.againstIsReachable(at: index) {
                return EffectNote(text: "The effect it blends against is gone or below this step, so it does nothing until pointed elsewhere.", dims: true)
            }
            // An adjustment blends with the picture it receives, which is
            // always there.
            if effect.against == nil, clip.source != .adjustment, isNested(timeline.id), !hasPicturesBelow(layer.id, in: timeline) {
                return EffectNote(text: "Nothing is under this clip in a nested timeline, so there is nothing to blend with.", dims: true)
            }
        }
        if passesThrough(clip), effect.kind == .transform, let opacity = effect.control(.opacity), !opacity.isNoOp {
            return EffectNote(text: "With Pass Through, opacity applies to each layer inside, which differs from the whole where they overlap.", dims: false)
        }
        return Self.flashingNote(for: effect)
    }

    /// A warning on the looks that can flash more than three times a
    /// second (see docs/psychedelic-effects.md, "Safety: flashing"), as its
    /// package's `flashes` says: Static and Feedback always, Block Glitch
    /// and Hue Cycle when set faster than that. Their defaults stay below
    /// it.
    static func flashingNote(for effect: Effect) -> EffectNote? {
        guard let package = effect.kind.definition.package else { return nil }
        let flashes = switch package.flashes {
        case .never: false
        case .always: true
        case .when(let condition): condition.number(FastestValues(effect: effect, package: package)) != 0
        }
        guard flashes else { return nil }
        return EffectNote(
            text: "This can flash more than three times a second, which can trigger seizures in people with photosensitive epilepsy.",
            dims: false
        )
    }

    /// What a package's flashing condition reads: each control at the value
    /// of largest size it takes, off or deleted at its default.
    private struct FastestValues: EffectExpression.Values {
        let effect: Effect
        let package: EffectPackage

        func value(_ name: String) -> [Double] {
            guard let kind = effect.kind.controlKind(savedAs: name), let definition = package.controls.first(where: { $0.kind == kind }) else {
                return [0]
            }
            guard let control = effect.control(kind), control.enabled else { return definition.defaultValues }
            let values = control.number.isAnimated ? control.number.keyframes.map(\.value.values) : [control.number.value.values]
            return values.max { ($0.map(abs).max() ?? 0) < ($1.map(abs).max() ?? 0) } ?? definition.defaultValues
        }

        func center(_ name: String) -> [Double] { value(name) }

        func index(_ name: String) -> Double {
            guard let kind = effect.kind.controlKind(savedAs: name), let definition = package.controls.first(where: { $0.kind == kind }) else {
                return 0
            }
            let choice = effect.control(kind).flatMap { $0.enabled ? $0.choice : nil } ?? definition.defaultChoice
            return Double(definition.choiceOptions.firstIndex { $0.id == choice } ?? 0)
        }
    }

    /// Whether a Stroke at `index` has shapes above it to outline: one that
    /// is on, with no Matte or Blending step between, which change what the
    /// shapes cover.
    static func strokeHasShapes(_ effects: [Effect], at index: Int) -> Bool {
        for effect in effects.prefix(index).reversed() where effect.enabled {
            if effect.kind.drawsShape { return true }
            if effect.kind == .matte || effect.kind == .blending || effect.kind.category == .distortion { return false }
        }
        return false
    }

    /// A note on one of a clip's transitions, when Pass Through can't draw it.
    func note(for transition: ClipTransition, of clip: TimelineClip) -> EffectNote? {
        guard passesThrough(clip) else { return nil }
        // A wipe crops and a film dissolve keys one picture. Moves and
        // fades apply to each layer, and the transitions drawn from two
        // whole pictures take the layers as drawn over what's under them.
        switch transition.kind {
        case .wipe, .filmDissolve:
            return EffectNote(text: "Pass Through can't apply this: it needs one combined picture.", dims: true)
        default:
            return nil
        }
    }

    /// The project as the viewer shows it for Show Up to Here: the clip as
    /// it is after the effect, with the effects below it and its
    /// transitions skipped. The project itself isn't changed.
    func showing(upTo effectID: UUID, ofClip clipID: UUID, in timelineID: UUID) -> EditingProject {
        var shown = self
        shown.editClip(clipID, in: timelineID) { clip in
            guard let index = clip.effects.index(of: effectID) else { return }
            clip.effects = Array(clip.effects.prefix(index + 1))
            clip.transitionIn = nil
            clip.transitionOut = nil
        }
        return shown
    }

    /// Whether an effect is in a clip's stack.
    func hasEffect(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID) -> Bool {
        clipAndLayer(clipID, in: timelineID)?.clip.effects.contains { $0.id == effectID } ?? false
    }
}
