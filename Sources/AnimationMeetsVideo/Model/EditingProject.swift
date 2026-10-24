import AVFoundation
import CoreMedia
import Foundation

struct EditingProject: Identifiable, Equatable {
    let id: UUID
    var name: String
    var clips: [MediaClip]
    var timelines: [Timeline]
    /// The project's Main timeline: the one the editor opens on and falls
    /// back to when the timeline it shows goes away, and the only one the
    /// tape scrubber plays.
    var rootTimelineID: UUID
    /// Cut sensitivity for assets that don't override it, from 0 (only
    /// obvious cuts) to 1 (small changes count).
    var defaultSensitivity = EditingProject.balancedSensitivity
    /// Whether imported media is copied into the package's `Media/` folder
    /// (the default) or referenced where it is.
    var copiesMediaOnImport = true
    /// How much of the frame, on each side, an intermediate image keeps of
    /// the picture moved off the frame, as a fraction of its width and
    /// height. See `defaultCanvasMargin`.
    var canvasMargin = EditingProject.defaultCanvasMargin

    /// Half a frame on each side: twice the frame's area.
    static let defaultCanvasMargin = 0.5

    /// The default sensitivity for a new project: a balanced setting.
    static let balancedSensitivity = 0.5

    static var empty: EditingProject {
        let main = Timeline(
            name: "Main",
            layers: [],
            frameSize: CGSize(width: 1920, height: 1080),
            frameRate: 24,
            colorSpace: .rec709
        )
        return EditingProject(id: UUID(), name: "Untitled Project", clips: [], timelines: [main], rootTimelineID: main.id)
    }

    /// Copies each asset's file location from `other`, leaving everything else
    /// alone. Used after a save moves media into the package, so edits made
    /// while the save was running are kept.
    mutating func applyMediaLocations(from other: EditingProject) {
        for clip in other.clips {
            if let index = clips.firstIndex(id: clip.id) {
                clips[index].url = clip.url
                clips[index].acceptedStamp = clip.acceptedStamp
            }
        }
    }

    func timeline(id: UUID) -> Timeline? {
        timelines.first(id: id)
    }

    func mediaClip(id: UUID) -> MediaClip? {
        clips.first(id: id)
    }

    func resolvedInfo(for source: ClipSource) -> ResolvedClipInfo? {
        switch source {
        case .adjustment:
            return .adjustment
        case .graphic:
            return .graphic
        case .media(let mediaID):
            guard let clip = mediaClip(id: mediaID) else { return nil }
            return .media(clip)
        case .timeline(let timelineID):
            guard let timeline = timeline(id: timelineID) else { return nil }
            return .timeline(timeline)
        }
    }

    /// Adds an imported file to the media pool. It stays in the library
    /// until the person puts it on a timeline.
    mutating func addMedia(_ clip: MediaClip) {
        clips.append(clip)
    }

    /// Puts a whole asset on a new layer at the top of the stack, After
    /// Effects-style — each placed piece of footage gets its own layer
    /// rather than merging into a shared track.
    @discardableResult
    mutating func placeAsset(_ assetID: UUID, intoTimeline timelineID: UUID) -> (layerID: UUID, clipID: UUID)? {
        guard let clip = mediaClip(id: assetID),
              let index = timelines.firstIndex(id: timelineID)
        else {
            return nil
        }
        let timelineClip = coveringWholeFrames(
            TimelineClip(source: .media(clip.id), startOffset: .zero, trimStart: .zero, trimEnd: clip.duration),
            in: timelines[index]
        )
        let layer = TimelineLayer(customName: nil, kind: defaultLayerKind(forAsset: assetID), clips: [timelineClip])
        timelines[index].layers.insert(layer, at: 0)
        return (layer.id, timelineClip.id)
    }

    /// Adds a file to the media pool and places it on a timeline in one
    /// step. Importing in the app only adds to the pool; this is for setting
    /// up projects in code, such as in tests.
    @discardableResult
    mutating func importClip(_ clip: MediaClip, intoTimeline timelineID: UUID) -> (layerID: UUID, clipID: UUID)? {
        addMedia(clip)
        return placeAsset(clip.id, intoTimeline: timelineID)
    }

    @discardableResult
    mutating func addTimeline(name: String, frameSize: CGSize, frameRate: Double, colorSpace: ProjectColorSpace) -> UUID {
        let timeline = Timeline(name: name, layers: [], frameSize: frameSize, frameRate: frameRate, colorSpace: colorSpace)
        timelines.append(timeline)
        return timeline.id
    }

    /// Changes a timeline's settings. A new frame rate also moves what is
    /// on the timeline onto its frames; see `alignToFrames(timeline:)`.
    mutating func updateTimelineSettings(_ id: UUID, name: String, frameSize: CGSize, frameRate: Double, colorSpace: ProjectColorSpace) {
        guard let index = timelines.firstIndex(id: id) else { return }
        let oldFrame = timelines[index].frameDuration
        timelines[index].name = name
        timelines[index].frameSize = frameSize
        timelines[index].frameRate = frameRate
        timelines[index].colorSpace = colorSpace
        if timelines[index].frameDuration != oldFrame {
            alignToFrames(timeline: id)
        }
    }

    /// A timeline can't be embedded into itself or into any timeline it
    /// already contains (directly or transitively) — that would be a cycle.
    /// Nor can an empty one, which would make a clip with no length.
    func canEmbed(_ timelineID: UUID, into targetTimelineID: UUID) -> Bool {
        guard let nested = timeline(id: timelineID), nested.duration > .zero else { return false }
        var visited: Set<UUID> = []
        collectNestedTimelineIDs(startingFrom: timelineID, visited: &visited)
        return !visited.contains(targetTimelineID)
    }

    func collectNestedTimelineIDs(startingFrom timelineID: UUID, visited: inout Set<UUID>) {
        guard visited.insert(timelineID).inserted, let timeline = timeline(id: timelineID) else { return }
        for layer in timeline.layers {
            for clip in layer.clips {
                if case .timeline(let nestedID) = clip.source {
                    collectNestedTimelineIDs(startingFrom: nestedID, visited: &visited)
                }
                // A timeline used as an effect's input is inside this one too.
                for effect in clip.effects {
                    if case .timeline(let inputID)? = effect.input?.source {
                        collectNestedTimelineIDs(startingFrom: inputID, visited: &visited)
                    }
                }
            }
        }
    }

    @discardableResult
    mutating func embedTimeline(_ timelineID: UUID, intoTimeline targetTimelineID: UUID) -> (layerID: UUID, clipID: UUID)? {
        guard canEmbed(timelineID, into: targetTimelineID),
              let nested = timeline(id: timelineID),
              let index = timelines.firstIndex(id: targetTimelineID)
        else {
            return nil
        }
        let timelineClip = coveringWholeFrames(
            TimelineClip(source: .timeline(timelineID), startOffset: .zero, trimStart: .zero, trimEnd: nested.duration),
            in: timelines[index]
        )
        let layer = TimelineLayer(customName: nil, kind: .video, clips: [timelineClip])
        timelines[index].layers.insert(layer, at: 0)
        return (layer.id, timelineClip.id)
    }

    /// Repositions a clip within its layer by setting its absolute start
    /// time — the drag-to-move interaction in the timeline UI. Where it
    /// lands, and which clips move right to make room for it, is
    /// `resolvedMove(ofMoving:in:layer:onto:to:)`.
    ///
    /// With `targetLayerID` the clip moves to that layer instead, so several
    /// clips can share a layer. A layer left empty stays, so clips can be
    /// moved back into it; `deleteLayer` removes it.
    mutating func moveClip(_ id: UUID, in timelineID: UUID, layer layerID: UUID, onto targetLayerID: UUID? = nil, to newStart: CMTime) {
        guard let move = resolvedMove(ofMoving: id, in: timelineID, layer: layerID, onto: targetLayerID, to: newStart),
              let tIndex = timelines.firstIndex(id: timelineID),
              let lIndex = timelines[tIndex].layers.firstIndex(id: layerID),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(id: id),
              let targetIndex = targetLayerID.map({ timelines[tIndex].layers.firstIndex(id: $0) }) ?? lIndex
        else {
            return
        }
        var clip = timelines[tIndex].layers[lIndex].clips.remove(at: cIndex)
        clip.startOffset = move.start
        if move.push > .zero {
            for c in timelines[tIndex].layers[targetIndex].clips.indices
            where timelines[tIndex].layers[targetIndex].clips[c].startOffset >= move.pushFrom {
                timelines[tIndex].layers[targetIndex].clips[c].startOffset = CMTimeAdd(
                    timelines[tIndex].layers[targetIndex].clips[c].startOffset, move.push
                )
            }
        }
        timelines[tIndex].layers[targetIndex].clips.append(clip)
        timelines[tIndex].layers[targetIndex].clips.sort { $0.startOffset < $1.startOffset }
    }

    /// Splits the clip at a timeline-space time (e.g. the playhead). The time
    /// must fall strictly inside the clip's placed range.
    mutating func split(_ id: UUID, in timelineID: UUID, layer layerID: UUID, atTimelineTime time: CMTime) {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let lIndex = timelines[tIndex].layers.firstIndex(id: layerID),
              let clip = timelines[tIndex].layers[lIndex].clips.first(id: id)
        else {
            return
        }
        Self.split(&timelines[tIndex].layers[lIndex].clips, id: id, at: clip.sourceTime(atTimelineTime: time), startingSecondAt: time)
    }

    /// Removes a clip from its layer. The layer stays, even when empty.
    mutating func deleteClip(_ id: UUID, in timelineID: UUID, layer layerID: UUID) {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let lIndex = timelines[tIndex].layers.firstIndex(id: layerID)
        else {
            return
        }
        timelines[tIndex].layers[lIndex].clips.removeAll { $0.id == id }
    }

    /// Removes a layer and every clip on it. An adjustment clip that
    /// reached down to it goes back to reaching every layer below.
    mutating func deleteLayer(_ layerID: UUID, in timelineID: UUID) {
        guard let tIndex = timelines.firstIndex(id: timelineID) else { return }
        timelines[tIndex].layers.removeAll { $0.id == layerID }
        for l in timelines[tIndex].layers.indices {
            for c in timelines[tIndex].layers[l].clips.indices where timelines[tIndex].layers[l].clips[c].reach == layerID {
                timelines[tIndex].layers[l].clips[c].reach = nil
            }
        }
    }

    mutating func split(_ id: UUID, in timelineID: UUID, layer layerID: UUID, at time: CMTime) {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let lIndex = timelines[tIndex].layers.firstIndex(id: layerID)
        else {
            return
        }
        Self.split(&timelines[tIndex].layers[lIndex].clips, id: id, at: time)
    }

    mutating func renameLayer(_ layerID: UUID, in timelineID: UUID, to name: String?) {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let lIndex = timelines[tIndex].layers.firstIndex(id: layerID)
        else {
            return
        }
        timelines[tIndex].layers[lIndex].customName = name
    }

    /// Moves a layer to `index` in the stack (0 is the top), as when its
    /// header is dragged.
    mutating func moveLayer(_ layerID: UUID, in timelineID: UUID, toIndex index: Int) {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let from = timelines[tIndex].layers.firstIndex(id: layerID)
        else {
            return
        }
        let layer = timelines[tIndex].layers.remove(at: from)
        timelines[tIndex].layers.insert(layer, clampedAt: index)
    }

    /// Moves a layer `offset` places up (negative) or down among the layers
    /// of its own kind, which are all its area of the timeline shows.
    /// Layers of other kinds keep their places.
    mutating func moveLayer(_ layerID: UUID, in timelineID: UUID, by offset: Int) {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let index = timelines[tIndex].layers.firstIndex(id: layerID)
        else {
            return
        }
        let kind = timelines[tIndex].layers[index].kind
        let slots = timelines[tIndex].layers.indices.filter { timelines[tIndex].layers[$0].kind == kind }
        guard let position = slots.firstIndex(of: index), slots.indices.contains(position + offset) else { return }
        // The layers of this kind move through their own slots, so the
        // ones between shift by one and other kinds stay where they are.
        var sameKind = slots.map { timelines[tIndex].layers[$0] }
        sameKind.insert(sameKind.remove(at: position), at: position + offset)
        for (slot, layer) in zip(slots, sameKind) {
            timelines[tIndex].layers[slot] = layer
        }
    }

    /// Moves a layer to `position` among the layers of its own kind (0 is
    /// the top of its area), as when its header is dragged. Layers of other
    /// kinds keep their places.
    mutating func moveLayer(_ layerID: UUID, in timelineID: UUID, toPositionInKind position: Int) {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let from = timelines[tIndex].layers.firstIndex(id: layerID)
        else {
            return
        }
        let layer = timelines[tIndex].layers.remove(at: from)
        let sameKind = timelines[tIndex].layers.indices.filter { timelines[tIndex].layers[$0].kind == layer.kind }
        let index: Int
        if sameKind.indices.contains(position) {
            index = sameKind[max(0, position)]
        } else if let last = sameKind.last {
            index = last + 1
        } else {
            index = from
        }
        timelines[tIndex].layers.insert(layer, at: min(index, timelines[tIndex].layers.count))
    }

    mutating func setAutoMatteEnabled(_ enabled: Bool, for id: UUID, in timelineID: UUID, layer layerID: UUID) {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let lIndex = timelines[tIndex].layers.firstIndex(id: layerID),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(id: id)
        else {
            return
        }
        timelines[tIndex].layers[lIndex].clips[cIndex].autoMatteEnabled = enabled
    }

    /// Drags the clip's leading edge, non-destructively revealing or hiding
    /// source frames. Unlike a plain move, trimming the start keeps the
    /// clip's *end* fixed in time; see `resolvedTrimStart(of:in:layer:to:)`.
    mutating func trimClipStart(_ id: UUID, in timelineID: UUID, layer layerID: UUID, to proposedTrimStart: CMTime) {
        guard let trimmed = resolvedTrimStart(of: id, in: timelineID, layer: layerID, to: proposedTrimStart) else { return }
        replaceClip(trimmed, in: timelineID, layer: layerID)
    }

    /// Drags the clip's trailing edge; the start stays fixed and only the
    /// trimmed-out duration changes. See `resolvedTrimEnd(of:in:layer:to:)`.
    mutating func trimClipEnd(_ id: UUID, in timelineID: UUID, layer layerID: UUID, to proposedTrimEnd: CMTime) {
        guard let trimmed = resolvedTrimEnd(of: id, in: timelineID, layer: layerID, to: proposedTrimEnd) else { return }
        replaceClip(trimmed, in: timelineID, layer: layerID)
    }

    /// Slips a clip's footage (see `resolvedSlip`). When that shortens the
    /// clip, every later clip on its layer moves in by as much, so no gap
    /// opens after it.
    mutating func slipClip(_ id: UUID, in timelineID: UUID, layer layerID: UUID, by delta: CMTime) {
        guard let slipped = resolvedSlip(of: id, in: timelineID, layer: layerID, by: delta) else { return }
        applyRipple(slipped, in: timelineID, layer: layerID)
    }

    /// Replaces a clip and moves every clip after it on the layer by as
    /// much as its end moved.
    mutating func applyRipple(_ trimmed: TimelineClip, in timelineID: UUID, layer layerID: UUID) {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let lIndex = timelines[tIndex].layers.firstIndex(id: layerID),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(id: trimmed.id)
        else {
            return
        }
        let originalEnd = timelines[tIndex].layers[lIndex].clips[cIndex].endOffset
        let shift = CMTimeSubtract(trimmed.endOffset, originalEnd)
        for index in timelines[tIndex].layers[lIndex].clips.indices where index != cIndex {
            let start = timelines[tIndex].layers[lIndex].clips[index].startOffset
            if start >= originalEnd {
                // A clip that met this one's end (give or take the rounding
                // of a retimed end) still meets it, on the frame the end
                // is at: a retimed end can be a few microseconds off its
                // frame, which `closingSlivers` covers when building, but
                // the next clip stays on a frame.
                let abuts = CMTimeSubtract(start, originalEnd) < Timeline.abutmentTolerance
                let follower = timelines[tIndex].layers[lIndex].clips[index]
                let meeting = isFrameLocked(follower) ? timelines[tIndex].frameAligned(trimmed.endOffset, .nearest) : trimmed.endOffset
                timelines[tIndex].layers[lIndex].clips[index].startOffset = abuts ? meeting : CMTimeAdd(start, shift)
            }
        }
        timelines[tIndex].layers[lIndex].clips[cIndex] = trimmed
    }

    private mutating func replaceClip(_ clip: TimelineClip, in timelineID: UUID, layer layerID: UUID) {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let lIndex = timelines[tIndex].layers.firstIndex(id: layerID),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(id: clip.id)
        else {
            return
        }
        timelines[tIndex].layers[lIndex].clips[cIndex] = clip
    }

    /// Splits at source time `time`. The second half starts at
    /// `startingSecondAt` in the timeline, or where that source time plays.
    static func split(_ clips: inout [TimelineClip], id: UUID, at time: CMTime, startingSecondAt secondStartTime: CMTime? = nil) {
        guard let index = clips.firstIndex(id: id) else { return }
        let clip = clips[index]
        guard time > clip.trimStart, time < clip.trimEnd else { return }
        // The split point is in source time; convert it to where that point
        // plays in the timeline, so the second half starts exactly where the
        // first half now ends — no gap introduced by splitting, even though
        // either half can be dragged apart afterward.
        let secondStart = secondStartTime ?? clip.timelineTime(forSourceTime: time)
        // Both halves get new IDs, so nothing goes on pointing at the whole
        // clip as if it were one of them. A song's followers find their
        // piece again by time (see `MusicAttachment.songClipID`).
        // The first half keeps the way in, the second the way out.
        // (A backwards clip plays the later footage first.)
        var first = clip
        first.id = UUID()
        if clip.isReversed { first.trimStart = time } else { first.trimEnd = time }
        first.transitionOut = nil
        var second = clip
        second.id = UUID()
        second.startOffset = secondStart
        if clip.isReversed { second.trimEnd = time } else { second.trimStart = time }
        second.transitionIn = nil
        clips.replaceSubrange(index...index, with: [first, second])
    }
}
