import CoreMedia
import Foundation

// Copying effects, pasting them and applying presets (see docs/effects.md,
// "Copying and presets" and "Paste changes"). A paste can't always bring an
// effect over exactly, so each thing that didn't come along is flagged on
// the effect until the person marks it resolved.

/// Something an effect didn't bring over when it was pasted.
struct PasteChange: Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// Its input stayed behind: the media belongs to a project.
        case inputLeftBehind
        /// It read the picture before an effect that wasn't pasted, so it
        /// went back to the backdrop.
        case againstReset
        /// Keyframes landed outside the clip, so they don't play.
        case keyframesOutside
    }

    var kind: Kind
    /// The input's name; the name of the effect Against read; for keyframes
    /// outside, `"end"` or `"start"` of the clip.
    var detail: String
    /// For keyframes outside: how many.
    var count = 0

    var id: String { "\(kind.rawValue)|\(detail)|\(count)" }

    /// What the effects panel and the Paste Changes list say.
    var message: String {
        switch kind {
        case .inputLeftBehind:
            return "Input left behind (was \(detail))."
        case .againstReset:
            return "Against reset to Backdrop: Before \(detail) wasn't pasted."
        case .keyframesOutside:
            let noun = count == 1 ? "keyframe falls" : "keyframes fall"
            return detail == "start" ? "\(count) \(noun) before the start of this clip." : "\(count) \(noun) past the end of this clip."
        }
    }
}

/// Effects taken from a clip's stack, ready to be pasted or saved. Keyframe
/// times are kept from the start of the source clip's trimmed range, so
/// they land the same distance from the start of the clip they go onto.
struct EffectBundle: Equatable, Sendable {
    struct Effect: Equatable, Sendable {
        /// The effect with its input taken off.
        var effect: AnimationMeetsVideo.Effect
        /// What its input was called, if it had one.
        var inputName: String?
        /// What the effect it read was called, if it read one.
        var againstName: String?
    }

    var effects: [Effect]
    /// Keyframe times are counted from this source time.
    var origin: CMTime

    var isEmpty: Bool { effects.isEmpty }
}

extension EditingProject {
    /// The effects with these IDs in a clip's stacks, in the order of the
    /// stacks (the picture's, then the sound's), or both whole stacks for
    /// nil. Nil if there is nothing to copy.
    func bundle(ofEffects ids: Set<UUID>?, fromClip clipID: UUID, in timelineID: UUID) -> EffectBundle? {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip else { return nil }
        let chosen = (clip.effects + clip.audioEffects).filter { ids?.contains($0.id) ?? true }
        guard !chosen.isEmpty else { return nil }
        let names = Dictionary(clip.effects.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return EffectBundle(
            effects: chosen.map { effect in
                var bare = effect
                bare.input = nil
                bare.pasteChanges = []
                return EffectBundle.Effect(
                    effect: bare,
                    inputName: effect.input.flatMap { name(of: $0) ?? "missing media" },
                    againstName: effect.against.map { names[$0] ?? "an effect" }
                )
            },
            origin: clip.trimStart
        )
    }

    /// Pastes `bundle` into a clip's stacks at `index` (the end for nil),
    /// or in place of the whole stacks. Picture effects go in the picture's
    /// stack and sound effects in the sound's, each only if the clip has
    /// one; `index` counts in the stack the bundle's first effect goes to,
    /// and the other kind goes at the end of its own. Returns the IDs of
    /// the new effects; empty when the clip has nowhere to put them.
    @discardableResult
    mutating func paste(
        _ bundle: EffectBundle, ontoClip clipID: UUID, in timelineID: UUID, at index: Int? = nil, replacingStack: Bool = false
    ) -> [UUID] {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip, !bundle.isEmpty else { return [] }
        let firstIsAudio = bundle.effects[0].effect.kind.isAudio
        var newIDs: [UUID: UUID] = [:]
        var pastedIDs: [UUID] = []
        for isAudio in [false, true] {
            let items = bundle.effects.filter { $0.effect.kind.isAudio == isAudio }
            guard !items.isEmpty, isAudio ? playsAudio(clip) : hasEffectStack(clip) else { continue }
            let key: WritableKeyPath<TimelineClip, [Effect]> = isAudio ? \.audioEffects : \.effects
            let stack = paste(items, origin: bundle.origin, into: replacingStack ? [] : clip[keyPath: key], of: clip,
                              at: isAudio == firstIsAudio ? index : nil, newIDs: &newIDs, pasted: &pastedIDs)
            editClip(clipID, in: timelineID) { $0[keyPath: key] = stack }
        }
        if let pasted = clipAndLayer(clipID, in: timelineID)?.clip {
            for effect in pasted.effects where effect.kind.isKeyframing && pastedIDs.contains(effect.id) {
                regenerateKeyframes(ofEffect: effect.id, onClip: clipID, in: timelineID)
            }
        }
        return pastedIDs
    }

    /// `kept` with `items` pasted in at `index`, their keyframes moved to
    /// the clip and what couldn't come along noted.
    private func paste(
        _ items: [EffectBundle.Effect], origin: CMTime, into kept: [Effect], of clip: TimelineClip, at index: Int?,
        newIDs: inout [UUID: UUID], pasted pastedIDs: inout [UUID]
    ) -> [Effect] {
        let delta = CMTimeSubtract(clip.trimStart, origin)
        let allowed = CMTimeRange(start: clip.trimStart, end: clip.trimEnd)
        var stack = kept
        var pasted: [Effect] = []
        for item in items {
            var effect = item.effect.duplicated()
            newIDs[item.effect.id] = effect.id
            effect.input = nil
            effect.pasteChanges = []
            var changes: [PasteChange] = []

            if let inputName = item.inputName {
                changes.append(PasteChange(kind: .inputLeftBehind, detail: inputName))
            }
            // Against follows the effect it read when that came along above
            // it, and otherwise goes back to the backdrop.
            if let against = item.effect.against {
                if let mapped = newIDs[against] {
                    effect.against = mapped
                } else {
                    effect.against = nil
                    changes.append(PasteChange(kind: .againstReset, detail: item.againstName ?? "an effect"))
                }
            }
            var before = 0, after = 0
            for c in effect.controls.indices {
                effect.controls[c].number = effect.controls[c].number.shifted(by: delta)
                for keyframe in effect.controls[c].number.keyframes {
                    if keyframe.time < allowed.start { before += 1 } else if keyframe.time > allowed.end { after += 1 }
                }
            }
            if before > 0 { changes.append(PasteChange(kind: .keyframesOutside, detail: "start", count: before)) }
            if after > 0 { changes.append(PasteChange(kind: .keyframesOutside, detail: "end", count: after)) }
            effect.pasteChanges = changes

            // A name the person chose stays; a number that told it from the
            // others of its kind is given again for this stack.
            if effect.name == nil || Self.isAutomaticName(effect.name!, for: effect.kind) {
                effect.name = Effect.make(effect.kind, among: stack + pasted).name
            }
            pasted.append(effect)
        }
        // A Keyframing effect follows the control it wrote to when that came
        // along, and otherwise waits to be pointed at one. What it wrote
        // there is marked as the pasted effect's.
        for p in pasted.indices {
            guard let setup = pasted[p].keyframing else { continue }
            var moved = setup
            // The clip's own volume is still there to write to.
            moved.target = setup.target == .volume ? .volume : nil
            if case .control(let effectID, let controlID)? = setup.target,
               let original = items.first(where: { $0.effect.id == effectID })?.effect,
               let c = original.controlIndex(controlID), let newEffectID = newIDs[effectID],
               let t = pasted.firstIndex(where: { $0.id == newEffectID }), pasted[t].controls.indices.contains(c) {
                moved.target = .control(effectID: newEffectID, controlID: pasted[t].controls[c].id)
                moved.base = setup.base?.shifted(by: delta)
                let oldID = items[p].effect.id, newID = pasted[p].id
                let number = pasted[t].controls[c].number
                pasted[t].controls[c].number = AnimatedValue(number.value, keyframes: number.keyframes.map { keyframe in
                    var marked = keyframe
                    if marked.generatedBy == oldID { marked.generatedBy = newID }
                    return marked
                })
            }
            moved.range = setup.range.map { CMTimeRange(start: CMTimeAdd($0.start, delta), duration: $0.duration) }
            pasted[p].keyframing = moved
        }
        let at = min(max(index ?? kept.count, 0), kept.count)
        stack.insert(contentsOf: pasted, at: at)
        pastedIDs += pasted.map(\.id)
        return stack
    }

    /// Whether `name` is what the kind's name or a number on it would be.
    private static func isAutomaticName(_ name: String, for kind: EffectKind) -> Bool {
        if name == kind.name { return true }
        guard name.hasPrefix(kind.name + " ") else { return false }
        return Int(name.dropFirst(kind.name.count + 1)) != nil
    }
}

// MARK: - Resolving

/// One unresolved paste change with where it is, for the Paste Changes list.
struct PasteChangeEntry: Identifiable, Equatable, Sendable {
    var timelineID: UUID
    var timelineName: String
    var clipID: UUID
    var clipName: String
    var effectID: UUID
    var effectName: String
    var change: PasteChange

    var id: String { "\(effectID.uuidString)|\(change.id)" }
}

extension EditingProject {
    /// The timeline and every timeline inside it, nested or used as an
    /// input, which an export of it draws.
    func timelineIDsDrawn(by timelineID: UUID) -> [UUID] {
        var visited: Set<UUID> = []
        collectNestedTimelineIDs(startingFrom: timelineID, visited: &visited)
        return timelines.map(\.id).filter { visited.contains($0) }
    }

    /// Every unresolved paste change in the timelines an export of
    /// `timelineID` draws (all timelines for nil).
    func unresolvedPasteChanges(drawnBy timelineID: UUID? = nil) -> [PasteChangeEntry] {
        let ids = timelineID.map { Set(timelineIDsDrawn(by: $0)) }
        var entries: [PasteChangeEntry] = []
        for timeline in timelines where ids?.contains(timeline.id) ?? true {
            for layer in timeline.layers {
                for clip in layer.clips {
                    for effect in clip.effects + clip.audioEffects {
                        for change in effect.pasteChanges {
                            entries.append(PasteChangeEntry(
                                timelineID: timeline.id, timelineName: timeline.name,
                                clipID: clip.id, clipName: resolvedInfo(for: clip.source)?.name ?? "Clip",
                                effectID: effect.id, effectName: effect.displayName, change: change
                            ))
                        }
                    }
                }
            }
        }
        return entries
    }

    /// Marks one change resolved: it no longer shows or blocks export.
    mutating func resolvePasteChange(_ change: PasteChange, ofEffect effectID: UUID, onClip clipID: UUID, in timelineID: UUID) {
        editEffect(effectID, ofClip: clipID, in: timelineID) { $0.pasteChanges.removeAll { $0 == change } }
    }

    /// Resolves every change in `entries`.
    mutating func resolve(_ entries: [PasteChangeEntry]) {
        for entry in entries {
            resolvePasteChange(entry.change, ofEffect: entry.effectID, onClip: entry.clipID, in: entry.timelineID)
        }
    }

    /// Whether the clip has an effect with changes left to resolve.
    func hasUnresolvedPasteChanges(_ clip: TimelineClip) -> Bool {
        (clip.effects + clip.audioEffects).contains { !$0.pasteChanges.isEmpty }
    }
}
