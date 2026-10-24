import CoreMedia
import Foundation

// Copying clips, pasting them and duplicating them (see docs/timeline.md,
// "Copy, paste and duplicate"). A clip comes along whole: its trim, its
// effects and keyframes, its transitions, its time and shutter.

/// A clip copied from a timeline, ready to paste.
struct ClipBundle: Equatable {
    var clip: TimelineClip
    /// The kind of layer it came from, for a paste that needs a new layer.
    var layerKind: LayerKind
    /// Where it came from, so a paste into the same timeline can go back
    /// onto its layer.
    var timelineID: UUID
    var layerID: UUID
    /// What the clip needs from its project, for a paste into another.
    var sources = PasteSources()
}

extension TimelineClip {
    /// A copy with new IDs for the clip, its effects and their controls.
    /// What pointed from one of its effects to another (the picture an
    /// effect reads against, the control a Keyframing effect writes to, the
    /// keyframes it wrote) points at the copies.
    func duplicated() -> TimelineClip {
        var copy = self
        copy.id = UUID()
        var effectIDs: [UUID: UUID] = [:]
        var controlIDs: [UUID: UUID] = [:]
        func renew(_ stack: [Effect]) -> [Effect] {
            stack.map { effect in
                let renewed = effect.duplicated()
                effectIDs[effect.id] = renewed.id
                for (old, new) in zip(effect.controls, renewed.controls) { controlIDs[old.id] = new.id }
                return renewed
            }
        }
        copy.effects = renew(effects)
        copy.audioEffects = renew(audioEffects)

        func remap(_ stack: inout [Effect]) {
            for e in stack.indices {
                if let against = stack[e].against { stack[e].against = effectIDs[against] }
                if var setup = stack[e].keyframing, case .control(let effectID, let controlID)? = setup.target,
                   let newEffect = effectIDs[effectID], let newControl = controlIDs[controlID] {
                    // A new target lets go of the base; this is the same one.
                    let base = setup.base
                    setup.target = .control(effectID: newEffect, controlID: newControl)
                    setup.base = base
                    stack[e].keyframing = setup
                }
                for c in stack[e].controls.indices {
                    stack[e].controls[c].number = Self.remarked(stack[e].controls[c].number, effectIDs)
                }
            }
        }
        remap(&copy.effects)
        remap(&copy.audioEffects)
        copy.volume = Self.remarked(volume, effectIDs)
        copy.pan = Self.remarked(pan, effectIDs)
        return copy
    }

    /// `value` with keyframes a Keyframing effect wrote marked as its copy's.
    private static func remarked<V>(_ value: AnimatedValue<V>, _ effectIDs: [UUID: UUID]) -> AnimatedValue<V> {
        guard value.keyframes.contains(where: { $0.generatedBy != nil }) else { return value }
        return AnimatedValue(value.value, keyframes: value.keyframes.map { keyframe in
            var marked = keyframe
            if let by = marked.generatedBy { marked.generatedBy = effectIDs[by] ?? by }
            return marked
        })
    }
}

extension EditingProject {
    /// A clip to copy; nil for an unknown clip.
    func clipBundle(_ clipID: UUID, in timelineID: UUID) -> ClipBundle? {
        guard let (clip, layer) = clipAndLayer(clipID, in: timelineID) else { return nil }
        return ClipBundle(
            clip: clip, layerKind: layer.kind, timelineID: timelineID, layerID: layer.id,
            sources: pasteSources(for: [clip])
        )
    }

    /// Whether `bundle` can go into a timeline: anything can, except a
    /// nested timeline into itself or into one it contains. Media and
    /// timelines this project lacks come with the bundle when it was
    /// copied in another project (`PasteSources`).
    func canPaste(_ bundle: ClipBundle, into timelineID: UUID) -> Bool {
        guard timeline(id: timelineID) != nil else { return false }
        if case .timeline(let nestedID) = bundle.clip.source {
            return timeline(id: nestedID) != nil ? canEmbed(nestedID, into: timelineID) : bundle.sources.hasTimeline(nestedID)
        }
        if case .media(let assetID) = bundle.clip.source {
            return mediaClip(id: assetID) != nil || bundle.sources.hasMedia(assetID)
        }
        return true
    }

    /// Pastes a copy of `bundle`'s clip at `start`, landing as a clip moved
    /// there would: inside a clip it goes to the nearer edge, and the clips
    /// from there on move right to make room. It goes onto `layerID` when
    /// that layer takes it, else back onto the layer it came from when it
    /// is in this timeline, else onto a new layer of its kind at the top.
    /// Returns where it went; nil when it can't go into this timeline.
    @discardableResult
    mutating func paste(_ bundle: ClipBundle, in timelineID: UUID, onto layerID: UUID?, at start: CMTime) -> (layerID: UUID, clipID: UUID)? {
        guard canPaste(bundle, into: timelineID) else { return nil }
        adopt(bundle.sources)
        guard let tIndex = timelines.firstIndex(id: timelineID) else { return nil }
        let timeline = timelines[tIndex]
        var clip = coveringWholeFrames(bundle.clip.duplicated(), in: timeline)
        // An adjustment clip reaching a layer of another timeline reaches
        // every layer below instead.
        if let reach = clip.reach, timeline.layer(id: reach) == nil { clip.reach = nil }

        let candidates = [layerID, bundle.timelineID == timelineID ? bundle.layerID : nil].compactMap { $0 }
        if let target = candidates.compactMap({ id in timeline.layers.firstIndex(id: id) })
            .first(where: { layer(timeline.layers[$0], accepts: clip) }) {
            var others = timeline.layers[target].clips
            let move = insertion(lasting: clip.placedDuration, frameLocked: isFrameLocked(clip), among: others, in: timeline, at: start)
            others.makeRoom(for: move)
            clip.startOffset = move.start
            others.append(clip)
            timelines[tIndex].layers[target].clips = others.sorted { $0.startOffset < $1.startOffset }
            return (timeline.layers[target].id, clip.id)
        }

        return insertOnNewLayer(clip, kind: bundle.layerKind, in: tIndex, at: start)
    }

    /// Pastes a copy of `bundle`'s clip onto a new layer of `kind` (or of
    /// its own kind, if `kind` can't take it) at the top, from `start`: an
    /// Option-drag of a clip over the layer names.
    @discardableResult
    mutating func paste(_ bundle: ClipBundle, in timelineID: UUID, newLayer kind: LayerKind, at start: CMTime) -> (layerID: UUID, clipID: UUID)? {
        guard canPaste(bundle, into: timelineID) else { return nil }
        adopt(bundle.sources)
        guard let tIndex = timelines.firstIndex(id: timelineID) else { return nil }
        var clip = coveringWholeFrames(bundle.clip.duplicated(), in: timelines[tIndex])
        if let reach = clip.reach, timelines[tIndex].layer(id: reach) == nil { clip.reach = nil }
        return insertOnNewLayer(clip, kind: kind, in: tIndex, at: start)
    }

    private mutating func insertOnNewLayer(_ clip: TimelineClip, kind wanted: LayerKind, in tIndex: Int, at start: CMTime) -> (layerID: UUID, clipID: UUID) {
        var clip = clip
        clip.startOffset = timelines[tIndex].placementTime(CMTimeMaximum(.zero, start), .nearest, frameLocked: isFrameLocked(clip))
        let kind = layerKind(wanted, accepts: clip) ? wanted : (isAudioOnly(clip) ? .sound : .video)
        var layer = TimelineLayer(customName: nil, kind: kind, clips: [clip])
        layer.isAdjustment = clip.source == .adjustment
        timelines[tIndex].layers.insert(layer, at: 0)
        return (layer.id, clip.id)
    }

    /// Puts a copy of a layer, its clips and sound effects with new IDs, at
    /// `position` among the layers of its kind (as `moveLayer(_:in:
    /// toPositionInKind:)` counts, the copy left out), or just below the
    /// layer for nil. A name given to the layer gets "copy" after it, as
    /// the Finder names a copy. Returns the copy's ID.
    @discardableResult
    mutating func duplicateLayer(_ layerID: UUID, in timelineID: UUID, toPositionInKind position: Int? = nil) -> UUID? {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let from = timelines[tIndex].layers.firstIndex(id: layerID)
        else { return nil }
        var copy = timelines[tIndex].layers[from]
        copy.id = UUID()
        copy.customName = copy.customName.map { "\($0) copy" }
        copy.clips = copy.clips.map { $0.duplicated() }
        copy.audioEffects = copy.audioEffects.map { $0.duplicated() }
        timelines[tIndex].layers.insert(copy, at: from + 1)
        if let position { moveLayer(copy.id, in: timelineID, toPositionInKind: position) }
        return copy.id
    }

    /// Puts a copy of a clip right after it on its layer, moving what
    /// follows along to make room. Returns the copy's ID.
    @discardableResult
    mutating func duplicateClip(_ clipID: UUID, in timelineID: UUID) -> UUID? {
        guard let bundle = clipBundle(clipID, in: timelineID) else { return nil }
        return paste(bundle, in: timelineID, onto: bundle.layerID, at: bundle.clip.endOffset)?.clipID
    }
}
