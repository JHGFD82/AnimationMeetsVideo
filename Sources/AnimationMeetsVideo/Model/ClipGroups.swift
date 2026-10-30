import CoreMedia
import Foundation

// Working on several clips at once: the clips a lasso picks up are copied,
// pasted, duplicated, deleted or put in a timeline of their own together
// (see docs/timeline.md, "Selecting several clips").

/// Clips copied together from a timeline, keeping where they sit relative
/// to each other in time and across layers.
struct ClipGroupBundle: Equatable {
    /// In the order they should be pasted: by start, then top layer first.
    var bundles: [ClipBundle]
    /// Where the earliest of them starts.
    var start: CMTime
    /// Where the latest of them ends.
    var end: CMTime
}

extension EditingProject {
    /// The clips with these IDs in a timeline, for a copy; nil when none of
    /// them is there.
    func clipGroup(_ ids: Set<UUID>, in timelineID: UUID) -> ClipGroupBundle? {
        guard let timeline = timeline(id: timelineID) else { return nil }
        var found: [(layer: Int, bundle: ClipBundle)] = []
        for (index, layer) in timeline.layers.enumerated() {
            for clip in layer.clips where ids.contains(clip.id) {
                found.append((index, ClipBundle(
                    clip: clip, layerKind: layer.kind, timelineID: timelineID, layerID: layer.id,
                    sources: pasteSources(for: [clip])
                )))
            }
        }
        guard let first = found.first else { return nil }
        found.sort { ($0.bundle.clip.startOffset, $0.layer) < ($1.bundle.clip.startOffset, $1.layer) }
        let start = found.map(\.bundle.clip.startOffset).reduce(first.bundle.clip.startOffset) { CMTimeMinimum($0, $1) }
        let end = found.map(\.bundle.clip.endOffset).reduce(first.bundle.clip.endOffset) { CMTimeMaximum($0, $1) }
        return ClipGroupBundle(bundles: found.map(\.bundle), start: start, end: end)
    }

    /// Whether every clip of `group` can go into a timeline.
    func canPaste(_ group: ClipGroupBundle, into timelineID: UUID) -> Bool {
        !group.bundles.isEmpty && group.bundles.allSatisfy { canPaste($0, into: timelineID) }
    }

    /// Pastes copies of a group's clips with the earliest at `start`, each
    /// as `paste(_:in:onto:at:)` places one. Clips that came from one layer
    /// go onto one layer: back onto it in the timeline they came from, else
    /// onto a new layer made for the first of them. Returns where each went
    /// (empty when the group can't go into this timeline).
    @discardableResult
    mutating func paste(_ group: ClipGroupBundle, in timelineID: UUID, at start: CMTime) -> [(layerID: UUID, clipID: UUID)] {
        guard canPaste(group, into: timelineID) else { return [] }
        var placed: [(layerID: UUID, clipID: UUID)] = []
        var layerFor: [UUID: UUID] = [:]
        for bundle in group.bundles {
            let at = CMTimeAdd(start, CMTimeSubtract(bundle.clip.startOffset, group.start))
            guard let result = paste(bundle, in: timelineID, onto: layerFor[bundle.layerID], at: at) else { continue }
            layerFor[bundle.layerID] = result.layerID
            placed.append(result)
        }
        return placed
    }

    /// Puts copies of the clips right after the group on their own layers,
    /// moving what follows along. Returns the copies.
    @discardableResult
    mutating func duplicateClips(_ ids: Set<UUID>, in timelineID: UUID) -> [(layerID: UUID, clipID: UUID)] {
        guard let group = clipGroup(ids, in: timelineID) else { return [] }
        return paste(group, in: timelineID, at: group.end)
    }

    /// Removes the clips from their layers, which stay.
    mutating func deleteClips(_ ids: Set<UUID>, in timelineID: UUID) {
        guard let tIndex = timelines.firstIndex(id: timelineID) else { return }
        for l in timelines[tIndex].layers.indices {
            timelines[tIndex].layers[l].clips.removeAll { ids.contains($0.id) }
        }
    }

    /// Takes the clips out of a timeline into a new one of its own, with the
    /// same frame size, rate and colors, their layers and their places in
    /// time and across layers kept, starting at zero; then puts that
    /// timeline in their place as one clip, on a new layer at the top,
    /// starting where the first of them did. Returns the new timeline and
    /// its clip; nil when none of the clips is there.
    @discardableResult
    mutating func nestClips(_ ids: Set<UUID>, in timelineID: UUID, named name: String) -> (timelineID: UUID, layerID: UUID, clipID: UUID)? {
        guard let group = clipGroup(ids, in: timelineID),
              let tIndex = timelines.firstIndex(id: timelineID)
        else { return nil }
        let source = timelines[tIndex]
        let nestedID = addTimeline(name: name, frameSize: source.frameSize, frameRate: source.frameRate, colorSpace: source.colorSpace)
        guard let nIndex = timelines.firstIndex(id: nestedID) else { return nil }

        // Their layers, topmost first, holding only the picked clips and
        // starting at zero; an adjustment's reach down to a layer left
        // behind goes back to every layer below.
        var layers: [TimelineLayer] = []
        for layer in source.layers {
            let picked = layer.clips.filter { ids.contains($0.id) }
            guard !picked.isEmpty else { continue }
            var copy = layer
            copy.clips = picked.map { clip in
                var moved = clip
                moved.startOffset = CMTimeSubtract(clip.startOffset, group.start)
                return moved
            }
            layers.append(copy)
        }
        let kept = Set(layers.map(\.id))
        for l in layers.indices {
            for c in layers[l].clips.indices {
                if let reach = layers[l].clips[c].reach, !kept.contains(reach) { layers[l].clips[c].reach = nil }
            }
        }
        timelines[nIndex].layers = layers
        deleteClips(ids, in: timelineID)

        let nested = timelines[nIndex]
        let clip = coveringWholeFrames(
            TimelineClip(source: .timeline(nestedID), startOffset: group.start, trimStart: .zero, trimEnd: nested.duration),
            in: timelines[tIndex]
        )
        let layer = TimelineLayer(customName: nil, kind: .video, clips: [clip])
        timelines[tIndex].layers.insert(layer, at: 0)
        return (nestedID, layer.id, clip.id)
    }
}

extension EditingProject {
    /// Turns the clips with these IDs in a timeline off, or on again when
    /// all of them are off already, as V does. False when none is there.
    @discardableResult
    mutating func toggleEnabled(ofClips ids: Set<UUID>, in timelineID: UUID) -> Bool {
        guard let tIndex = timelines.firstIndex(id: timelineID) else { return false }
        let clips = timelines[tIndex].layers.flatMap(\.clips).filter { ids.contains($0.id) }
        guard !clips.isEmpty else { return false }
        let enabled = clips.allSatisfy { !$0.enabled }
        for layer in timelines[tIndex].layers.indices {
            for clip in timelines[tIndex].layers[layer].clips.indices where ids.contains(timelines[tIndex].layers[layer].clips[clip].id) {
                timelines[tIndex].layers[layer].clips[clip].enabled = enabled
            }
        }
        return true
    }

    /// How far the clips with these IDs can move together toward `delta`:
    /// whole frames of the timeline, and no further back than the earliest
    /// of them starting at zero.
    func groupMoveDelta(_ ids: Set<UUID>, in timelineID: UUID, toward delta: CMTime) -> CMTime {
        guard let timeline = timeline(id: timelineID) else { return .zero }
        let starts = timeline.layers.flatMap(\.clips).filter { ids.contains($0.id) }.map(\.startOffset)
        guard let earliest = starts.min() else { return .zero }
        let frame = timeline.frameDuration
        let whole = CMTimeMultiplyByFloat64(frame, multiplier: (delta.seconds / frame.seconds).rounded())
        return CMTimeMaximum(whole, CMTimeSubtract(.zero, earliest))
    }

    /// Moves the clips with these IDs by `delta` together, each on its own
    /// layer (see `groupMoveDelta`). Clips not among them that would be
    /// covered are pushed later on their layer. Songs among them carry the
    /// footage attached to them, picked or not, as `followMusic(from:)`
    /// runs after the edit. False when nothing moved.
    @discardableResult
    mutating func moveClips(_ ids: Set<UUID>, in timelineID: UUID, by delta: CMTime) -> Bool {
        let delta = groupMoveDelta(ids, in: timelineID, toward: delta)
        guard delta != .zero, let tIndex = timelines.firstIndex(id: timelineID) else { return false }
        var moved = false
        for l in timelines[tIndex].layers.indices {
            var clips = timelines[tIndex].layers[l].clips
            guard clips.contains(where: { ids.contains($0.id) }) else { continue }
            for c in clips.indices where ids.contains(clips[c].id) {
                let start = CMTimeMaximum(.zero, CMTimeAdd(clips[c].startOffset, delta))
                clips[c].startOffset = timelines[tIndex].placementTime(start, .nearest, frameLocked: isFrameLocked(clips[c]))
            }
            timelines[tIndex].layers[l].clips = makingRoom(for: ids, among: clips, in: timelines[tIndex])
            moved = true
        }
        return moved
    }
}

extension Timeline {
    /// The clips from one clip to another, as Shift-click picks them: on
    /// the layers from the first's to the second's, every clip that
    /// overlaps the time from the earlier start to the later end.
    func clipRange(from anchorID: UUID, to clipID: UUID) -> Set<UUID> {
        guard let a = layers.firstIndex(where: { $0.clips.contains { $0.id == anchorID } }),
              let b = layers.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let anchor = layers[a].clips.first(where: { $0.id == anchorID }),
              let clip = layers[b].clips.first(where: { $0.id == clipID })
        else { return [clipID] }
        let start = CMTimeMinimum(anchor.startOffset, clip.startOffset)
        let end = CMTimeMaximum(anchor.endOffset, clip.endOffset)
        var ids: Set<UUID> = [anchorID, clipID]
        for layer in layers[min(a, b)...max(a, b)] {
            for candidate in layer.clips where candidate.startOffset < end && start < candidate.endOffset {
                ids.insert(candidate.id)
            }
        }
        return ids
    }
}
