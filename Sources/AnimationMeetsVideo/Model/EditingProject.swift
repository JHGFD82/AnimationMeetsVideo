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
    /// How attached sound crossfades under transitions joining two clips
    /// that don't choose their own shape (see `AudioCrossfade`).
    var jointAudioCrossfade = AudioCrossfade.sCurve

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

    /// Renames an asset in the browser; an empty name is ignored. Its file
    /// keeps its own name.
    mutating func renameMedia(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = clips.firstIndex(id: id) else { return }
        clips[index].name = trimmed
    }

    /// Turns finding an asset's scenes off (Don't Detect Scenes), which
    /// stops a search under way and shows it as one clip, or on again.
    mutating func setDetectsScenes(_ detects: Bool, ofAsset id: UUID) {
        guard let index = clips.firstIndex(id: id) else { return }
        clips[index].skipsSceneDetection = !detects
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
        guard let clip = mediaClip(id: assetID) else { return nil }
        return placeOnNewLayer(.media(clip.id), lasting: clip.duration, kind: defaultLayerKind(forAsset: assetID), in: timelineID)
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

    /// Renames a timeline; an empty name is ignored, since every timeline
    /// is listed and chosen by its name.
    mutating func renameTimeline(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        updateTimeline(id) { $0.name = trimmed }
    }

    /// Changes a timeline's settings. A new frame rate also moves what is
    /// on the timeline onto its frames; see `alignToFrames(timeline:)`.
    mutating func updateTimelineSettings(_ id: UUID, name: String, frameSize: CGSize, frameRate: Double, colorSpace: ProjectColorSpace) {
        let frameChanged = updateTimeline(id) { timeline in
            let oldFrame = timeline.frameDuration
            timeline.name = name
            timeline.frameSize = frameSize
            timeline.frameRate = frameRate
            timeline.colorSpace = colorSpace
            return timeline.frameDuration != oldFrame
        }
        if frameChanged == true {
            alignToFrames(timeline: id)
        }
    }

    /// Gives a timeline an asset's frame size (when known), frame rate and
    /// colour space, so it plays the asset as shot. A still has no frame
    /// rate, so the timeline keeps its own; so does anything left unknown.
    mutating func conformTimeline(_ id: UUID, to media: MediaClip, frameSize: CGSize?) {
        guard let timeline = timeline(id: id), media.kind.hasPictures else { return }
        let size = frameSize.map { CGSize(width: $0.width.rounded(), height: $0.height.rounded()) } ?? timeline.frameSize
        updateTimelineSettings(
            id, name: timeline.name, frameSize: size,
            frameRate: media.frameRate > 0 ? media.frameRate : timeline.frameRate, colorSpace: media.colorSpace
        )
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

    /// Embeds a timeline on a new layer at the top of `targetTimelineID`,
    /// all of it or, with `range`, only that stretch of it: the rest stays
    /// beyond the clip's trims, for transitions joining it to draw on.
    @discardableResult
    mutating func embedTimeline(
        _ timelineID: UUID, intoTimeline targetTimelineID: UUID, range: CMTimeRange? = nil
    ) -> (layerID: UUID, clipID: UUID)? {
        guard canEmbed(timelineID, into: targetTimelineID), let nested = timeline(id: timelineID) else { return nil }
        let whole = CMTimeRange(start: .zero, duration: nested.duration)
        let played = range.map { $0.intersection(whole) } ?? whole
        guard played.isValid, played.duration > .zero else { return nil }
        return placeOnNewLayer(.timeline(timelineID), from: played.start, lasting: played.duration, kind: .video, in: targetTimelineID)
    }

    /// A clip playing `source` from `start` for `duration`, covering whole
    /// frames, on a new layer at the top of the stack.
    private mutating func placeOnNewLayer(
        _ source: ClipSource, from start: CMTime = .zero, lasting duration: CMTime, kind: LayerKind, in timelineID: UUID
    ) -> (layerID: UUID, clipID: UUID)? {
        guard let timeline = timeline(id: timelineID) else { return nil }
        let clip = coveringWholeFrames(
            TimelineClip(source: source, startOffset: .zero, trimStart: start, trimEnd: CMTimeAdd(start, duration)),
            in: timeline
        )
        let layer = TimelineLayer(customName: nil, kind: kind, clips: [clip])
        updateTimeline(timelineID) { $0.layers.insert(layer, at: 0) }
        return (layer.id, clip.id)
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
        guard let move = resolvedMove(ofMoving: id, in: timelineID, layer: layerID, onto: targetLayerID, to: newStart) else { return }
        updateTimeline(timelineID) { timeline in
            guard let from = timeline.layers.firstIndex(id: layerID),
                  let index = timeline.layers[from].clips.firstIndex(id: id),
                  let to = targetLayerID.map({ timeline.layers.firstIndex(id: $0) }) ?? from
            else {
                return
            }
            var clip = timeline.layers[from].clips.remove(at: index)
            clip.startOffset = move.start
            timeline.layers[to].clips.makeRoom(for: move)
            timeline.layers[to].clips.append(clip)
            timeline.layers[to].clips.sort { $0.startOffset < $1.startOffset }
        }
    }

    /// Splits the clip at a timeline-space time (e.g. the playhead). The time
    /// must fall strictly inside the clip's placed range.
    mutating func split(_ id: UUID, in timelineID: UUID, layer layerID: UUID, atTimelineTime time: CMTime) {
        updateLayer(layerID, in: timelineID) { layer in
            guard let clip = layer.clips.first(id: id) else { return }
            layer.clips.splitClip(id, at: clip.sourceTime(atTimelineTime: time), startingSecondAt: time)
        }
    }

    /// Splits the clip at a time in its source.
    mutating func split(_ id: UUID, in timelineID: UUID, layer layerID: UUID, at time: CMTime) {
        updateLayer(layerID, in: timelineID) { $0.clips.splitClip(id, at: time) }
    }

    /// Removes a clip from its layer. The layer stays, even when empty.
    mutating func deleteClip(_ id: UUID, in timelineID: UUID, layer layerID: UUID) {
        updateLayer(layerID, in: timelineID) { $0.clips.removeAll { $0.id == id } }
    }

    mutating func setAutoMatteEnabled(_ enabled: Bool, for id: UUID, in timelineID: UUID, layer layerID: UUID) {
        updateClip(id, in: timelineID, layer: layerID) { $0.autoMatteEnabled = enabled }
    }

    mutating func renameLayer(_ layerID: UUID, in timelineID: UUID, to name: String?) {
        updateLayer(layerID, in: timelineID) { $0.customName = name }
    }

    // Arranging layers is the timeline's own business; see `Timeline`.

    mutating func deleteLayer(_ layerID: UUID, in timelineID: UUID) {
        updateTimeline(timelineID) { $0.deleteLayer(layerID) }
    }

    mutating func moveLayer(_ layerID: UUID, in timelineID: UUID, toIndex index: Int) {
        updateTimeline(timelineID) { $0.moveLayer(layerID, toIndex: index) }
    }

    mutating func moveLayer(_ layerID: UUID, in timelineID: UUID, by offset: Int) {
        updateTimeline(timelineID) { $0.moveLayer(layerID, by: offset) }
    }

    mutating func moveLayer(_ layerID: UUID, in timelineID: UUID, toPositionInKind position: Int) {
        updateTimeline(timelineID) { $0.moveLayer(layerID, toPositionInKind: position) }
    }

    /// Drags the clip's leading edge, non-destructively revealing or hiding
    /// source frames. Unlike a plain move, trimming the start keeps the
    /// clip's *end* fixed in time; see `resolvedTrimStart(of:in:layer:to:)`.
    mutating func trimClipStart(
        _ id: UUID, in timelineID: UUID, layer layerID: UUID, to proposedTrimStart: CMTime,
        sceneTracks: [UUID: ChangeScoreTrack]? = nil
    ) {
        guard let trimmed = resolvedTrimStart(of: id, in: timelineID, layer: layerID, to: proposedTrimStart, sceneTracks: sceneTracks) else { return }
        updateClip(id, in: timelineID, layer: layerID) { $0 = trimmed }
    }

    /// Drags the clip's trailing edge; the start stays fixed and only the
    /// trimmed-out duration changes. See `resolvedTrimEnd(of:in:layer:to:)`.
    mutating func trimClipEnd(
        _ id: UUID, in timelineID: UUID, layer layerID: UUID, to proposedTrimEnd: CMTime,
        sceneTracks: [UUID: ChangeScoreTrack]? = nil
    ) {
        guard let trimmed = resolvedTrimEnd(of: id, in: timelineID, layer: layerID, to: proposedTrimEnd, sceneTracks: sceneTracks) else { return }
        updateClip(id, in: timelineID, layer: layerID) { $0 = trimmed }
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
        guard let timeline = timeline(id: timelineID),
              let clips = timeline.layer(id: layerID)?.clips,
              let original = clips.first(id: trimmed.id)
        else {
            return
        }
        let originalEnd = original.endOffset
        let shift = CMTimeSubtract(trimmed.endOffset, originalEnd)
        var newStarts: [UUID: CMTime] = [:]
        for follower in clips where follower.id != trimmed.id && follower.startOffset >= originalEnd {
            // A clip that met this one's end (give or take the rounding
            // of a retimed end) still meets it, on the frame the end
            // is at: a retimed end can be a few microseconds off its
            // frame, which `closingSlivers` covers when building, but
            // the next clip stays on a frame.
            let abuts = CMTimeSubtract(follower.startOffset, originalEnd) < Timeline.abutmentTolerance
            let meeting = isFrameLocked(follower) ? timeline.frameAligned(trimmed.endOffset, .nearest) : trimmed.endOffset
            newStarts[follower.id] = abuts ? meeting : CMTimeAdd(follower.startOffset, shift)
        }
        updateLayer(layerID, in: timelineID) { layer in
            for index in layer.clips.indices {
                if layer.clips[index].id == trimmed.id {
                    layer.clips[index] = trimmed
                } else if let start = newStarts[layer.clips[index].id] {
                    layer.clips[index].startOffset = start
                }
            }
        }
    }

    // MARK: - Changing in place

    /// Runs `change` on the timeline, in place. Nil, and nothing changed,
    /// when there's no such timeline.
    @discardableResult
    mutating func updateTimeline<Result>(_ id: UUID, _ change: (inout Timeline) -> Result) -> Result? {
        guard let index = timelines.firstIndex(id: id) else { return nil }
        return change(&timelines[index])
    }

    /// Runs `change` on one of a timeline's layers, in place.
    @discardableResult
    mutating func updateLayer<Result>(_ layerID: UUID, in timelineID: UUID, _ change: (inout TimelineLayer) -> Result) -> Result? {
        updateTimeline(timelineID) { timeline -> Result? in
            guard let index = timeline.layers.firstIndex(id: layerID) else { return nil }
            return change(&timeline.layers[index])
        } ?? nil
    }

    /// Runs `change` on one of a layer's clips, in place.
    @discardableResult
    mutating func updateClip<Result>(
        _ clipID: UUID, in timelineID: UUID, layer layerID: UUID, _ change: (inout TimelineClip) -> Result
    ) -> Result? {
        updateLayer(layerID, in: timelineID) { layer -> Result? in
            guard let index = layer.clips.firstIndex(id: clipID) else { return nil }
            return change(&layer.clips[index])
        } ?? nil
    }
}
