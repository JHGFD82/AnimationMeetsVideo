import AVFoundation
import CoreMedia
import Foundation

struct EditingProject: Identifiable, Equatable {
    let id: UUID
    var name: String
    var clips: [MediaClip]
    var timelines: [Timeline]
    var rootTimelineID: UUID
    /// Cut sensitivity for assets that don't override it, from 0 (only
    /// obvious cuts) to 1 (small changes count).
    var defaultSensitivity = SceneDetector.balancedSensitivity
    /// Whether imported media is copied into the package's `Media/` folder
    /// (the default) or referenced where it is.
    var copiesMediaOnImport = true
    /// How much of the frame, on each side, an intermediate image keeps of
    /// the picture moved off the frame, as a fraction of its width and
    /// height. See `defaultCanvasMargin`.
    var canvasMargin = EditingProject.defaultCanvasMargin

    /// Half a frame on each side: twice the frame's area.
    static let defaultCanvasMargin = 0.5

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
            if let index = clips.firstIndex(where: { $0.id == clip.id }) {
                clips[index].url = clip.url
                clips[index].acceptedStamp = clip.acceptedStamp
            }
        }
    }

    func timeline(id: UUID) -> Timeline? {
        timelines.first { $0.id == id }
    }

    func mediaClip(id: UUID) -> MediaClip? {
        clips.first { $0.id == id }
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
              let index = timelines.firstIndex(where: { $0.id == timelineID })
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
        guard let index = timelines.firstIndex(where: { $0.id == id }) else { return }
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
    func canEmbed(_ timelineID: UUID, into targetTimelineID: UUID) -> Bool {
        if timelineID == targetTimelineID { return false }
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
              nested.duration > .zero,
              let index = timelines.firstIndex(where: { $0.id == targetTimelineID })
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
              let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(where: { $0.id == id })
        else {
            return
        }
        var clip = timelines[tIndex].layers[lIndex].clips.remove(at: cIndex)
        clip.startOffset = move.start
        var targetIndex = lIndex
        if let targetLayerID, let index = timelines[tIndex].layers.firstIndex(where: { $0.id == targetLayerID }) {
            targetIndex = index
        }
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
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              let clip = timelines[tIndex].layers[lIndex].clips.first(where: { $0.id == id })
        else {
            return
        }
        Self.split(&timelines[tIndex].layers[lIndex].clips, id: id, at: clip.sourceTime(atTimelineTime: time), startingSecondAt: time)
    }

    /// Removes a clip from its layer. The layer stays, even when empty.
    mutating func deleteClip(_ id: UUID, in timelineID: UUID, layer layerID: UUID) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        timelines[tIndex].layers[lIndex].clips.removeAll { $0.id == id }
    }

    /// Removes a layer and every clip on it. An adjustment clip that
    /// reached down to it goes back to reaching every layer below.
    mutating func deleteLayer(_ layerID: UUID, in timelineID: UUID) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }) else { return }
        timelines[tIndex].layers.removeAll { $0.id == layerID }
        for l in timelines[tIndex].layers.indices {
            for c in timelines[tIndex].layers[l].clips.indices where timelines[tIndex].layers[l].clips[c].reach == layerID {
                timelines[tIndex].layers[l].clips[c].reach = nil
            }
        }
    }

    mutating func split(_ id: UUID, in timelineID: UUID, layer layerID: UUID, at time: CMTime) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        Self.split(&timelines[tIndex].layers[lIndex].clips, id: id, at: time)
    }

    mutating func renameLayer(_ layerID: UUID, in timelineID: UUID, to name: String?) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        timelines[tIndex].layers[lIndex].customName = name
    }

    /// Moves a layer to `index` in the stack (0 is the top), as when its
    /// header is dragged.
    mutating func moveLayer(_ layerID: UUID, in timelineID: UUID, toIndex index: Int) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let from = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        let layer = timelines[tIndex].layers.remove(at: from)
        timelines[tIndex].layers.insert(layer, at: min(max(index, 0), timelines[tIndex].layers.count))
    }

    /// Moves a layer `offset` places up (negative) or down among the layers
    /// of its own kind, which are all its area of the timeline shows.
    /// Layers of other kinds keep their places.
    mutating func moveLayer(_ layerID: UUID, in timelineID: UUID, by offset: Int) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let index = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        let kind = timelines[tIndex].layers[index].kind
        let sameKind = timelines[tIndex].layers.indices.filter { timelines[tIndex].layers[$0].kind == kind }
        guard let position = sameKind.firstIndex(of: index), sameKind.indices.contains(position + offset) else { return }
        timelines[tIndex].layers.swapAt(index, sameKind[position + offset])
    }

    /// Moves a layer to `position` among the layers of its own kind (0 is
    /// the top of its area), as when its header is dragged. Layers of other
    /// kinds keep their places.
    mutating func moveLayer(_ layerID: UUID, in timelineID: UUID, toPositionInKind position: Int) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let from = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
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
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(where: { $0.id == id })
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
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(where: { $0.id == trimmed.id })
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
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(where: { $0.id == clip.id })
        else {
            return
        }
        timelines[tIndex].layers[lIndex].clips[cIndex] = clip
    }

    /// Splits at source time `time`. The second half starts at
    /// `startingSecondAt` in the timeline, or where that source time plays.
    static func split(_ clips: inout [TimelineClip], id: UUID, at time: CMTime, startingSecondAt secondStartTime: CMTime? = nil) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips[index]
        guard time > clip.trimStart, time < clip.trimEnd else { return }
        // The split point is in source time; convert it to where that point
        // plays in the timeline, so the second half starts exactly where the
        // first half now ends — no gap introduced by splitting, even though
        // either half can be dragged apart afterward.
        let secondStart = secondStartTime ?? clip.timelineTime(forSourceTime: time)
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

extension Timeline {
    /// Clips on a layer closer than this are taken to meet: the end of a
    /// retimed clip can't be found closer than the rounding of source
    /// time (4 µs), and a gap that small shows as a black frame.
    static let abutmentTolerance = CMTime(value: 1, timescale: 1000)

    /// The same timeline with every gap between clips on a layer smaller
    /// than `abutmentTolerance` closed, by moving the later clip to the
    /// earlier one's end.
    func closingSlivers() -> Timeline {
        var copy = self
        for layer in copy.layers.indices {
            let clips = copy.layers[layer].clips.sorted { $0.startOffset < $1.startOffset }
            var previousEnd: CMTime?
            var result: [TimelineClip] = []
            for var clip in clips {
                if let previousEnd {
                    let gap = CMTimeSubtract(clip.startOffset, previousEnd)
                    if gap > .zero, gap < Self.abutmentTolerance { clip.startOffset = previousEnd }
                }
                previousEnd = clip.endOffset
                result.append(clip)
            }
            // Keep the layer's own order of clips.
            let moved = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.startOffset) })
            for index in copy.layers[layer].clips.indices {
                copy.layers[layer].clips[index].startOffset = moved[copy.layers[layer].clips[index].id] ?? copy.layers[layer].clips[index].startOffset
            }
        }
        return copy
    }
}

extension Timeline {
    /// The same timeline without its disabled clips, which play as gaps.
    func withoutDisabledClips() -> Timeline {
        var copy = self
        for layer in copy.layers.indices { copy.layers[layer].clips.removeAll { !$0.enabled } }
        return copy
    }
}

/// A named sequence of numbered layers, After Effects-style. Timelines can
/// embed one another (nested/compound-clip style) via `ClipSource.timeline`.
struct Timeline: Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Index 0 is the topmost layer — matches After Effects' convention
    /// where newer/higher layers composite over lower ones.
    var layers: [TimelineLayer]
    var frameSize: CGSize
    var frameRate: Double
    var colorSpace: ProjectColorSpace
    /// Named stretches of time, in order, not overlapping.
    var sections: [TimelineSection] = []

    /// Up to the end of the last clip or section, whichever is later.
    var duration: CMTime {
        (layers.map(\.duration) + sections.map(\.end)).max(by: { $0.seconds < $1.seconds }) ?? .zero
    }

    var timebaseSummary: String {
        "\(Int(frameSize.width))×\(Int(frameSize.height)) · \(String(format: "%.2f", frameRate)) fps · \(colorSpace.rawValue)"
    }

    func layer(id: UUID) -> TimelineLayer? {
        layers.first { $0.id == id }
    }

    /// The clip in the given layer whose [startOffset, endOffset) range
    /// covers `time`, if any — nil if `time` falls in a gap.
    func clip(at time: CMTime, layer layerID: UUID) -> TimelineClip? {
        guard let layer = layer(id: layerID) else { return nil }
        return layer.clips.first { time >= $0.startOffset && time < $0.endOffset }
    }
}

struct TimelineLayer: Identifiable, Equatable {
    var id = UUID()
    /// User-assigned name, if any. Without one the timeline shows its kind
    /// and number, such as "Video 2".
    var customName: String?
    /// Which area of the timeline the layer sits in, and so which clips it
    /// takes. See `LayerKind`.
    var kind: LayerKind = .video
    var clips: [TimelineClip]
    /// The volume of everything a Sound or Music layer plays, applied after
    /// each clip's own, in decibels (see `AudioLevel`), keyframed in this
    /// timeline's time. Video layers have none, only their clips do.
    var volume = AnimatedValue(0.0)
    /// Where a Sound or Music layer's sound sits between the speakers,
    /// applied after each clip's own pan (see `AudioPan`), keyframed in
    /// this timeline's time.
    var pan = AnimatedValue(0.0)
    /// The sound effects a Sound or Music layer plays everything on it
    /// through, after each clip's own and before the layer's volume and
    /// pan, keyframed in this timeline's time. Video layers have none.
    var audioEffects: [Effect] = []
    /// Whether the layer holds adjustment clips (and only them), whose
    /// stacks are applied to the layers below. See docs/effects.md,
    /// "Adjustment layers". The layer is a video layer in every other way.
    var isAdjustment = false

    var duration: CMTime {
        clips.map(\.endOffset).max(by: { $0.seconds < $1.seconds }) ?? .zero
    }
}

enum ClipSource: Equatable {
    case media(UUID)
    case timeline(UUID)
    /// No picture of its own: its effect stack is applied to the layers
    /// below it. Only on an adjustment layer.
    case adjustment
    /// Starts from transparency, so its picture is what the shapes in its
    /// stack draw (see docs/graphic-layers.md).
    case graphic
}

/// A placement of a clip (raw media or a nested timeline) on a layer, with
/// its own non-destructive trim range and an independent, draggable
/// position in time — clips are not forced to be back-to-back or to start
/// at the timeline's t=0.
struct TimelineClip: Identifiable, Equatable {
    var id = UUID()
    var source: ClipSource
    var startOffset: CMTime
    var trimStart: CMTime
    var trimEnd: CMTime
    /// Non-destructive Vision-based foreground matte. Currently disabled in
    /// the UI pending a working live-preview capture pipeline; kept on the
    /// model since it's harmless and non-destructive by construction.
    var autoMatteEnabled: Bool = false
    /// Which of a media file's streams this clip plays. Always
    /// `.videoAndAudio` for nested timelines.
    var streams: ClipStreams = .videoAndAudio
    /// Brings the clip in at its start, and takes it out at its end.
    var transitionIn: ClipTransition?
    var transitionOut: ClipTransition?
    /// The point scale and rotation turn about: an offset from the center of
    /// the clip's fitted picture, in timeline pixels at 100% scale. Keyframed
    /// in the clip's source time, like everything on the clip. Clips with no
    /// pictures have none.
    var anchorPoint = AnimatedValue(Vector2.zero)
    /// What is done to the picture, top to bottom (see `Effect`).
    var effects: [Effect] = []
    /// What is done to the sound, top to bottom: effects whose kind
    /// `isAudio`, played before the clip's volume and pan.
    var audioEffects: [Effect] = []
    /// The volume of the clip's sound, in decibels (see `AudioLevel`),
    /// keyframed in the clip's source time. Clips with no sound have none.
    var volume = AnimatedValue(0.0)
    /// Where the clip's sound sits between the speakers (see `AudioPan`),
    /// keyframed in the clip's source time like its volume.
    var pan = AnimatedValue(0.0)
    /// For a nested timeline: draw its layers straight into the timeline
    /// it is placed in instead of as one picture (see docs/effects.md).
    var passThrough = false
    /// What the clip does to time (speed, frame blending, echo and sound),
    /// above its stack. See `ClipTime`.
    var time = ClipTime()
    /// What it does with its finished picture (motion blur and trails),
    /// below its transitions. See `ClipShutter`.
    var shutter = ClipShutter()
    /// For an adjustment clip: the lowest layer its effect reaches, stored
    /// as that layer's ID rather than a count so it stays put as layers are
    /// added and moved. Nil, or a layer not in its timeline, reaches every
    /// layer below.
    var reach: UUID?
    /// Off, the clip stays where it is on its layer but plays nothing: it
    /// is left out of the picture, the sound and exports, as a gap (V).
    var enabled = true
    /// Silences the clip's sound without taking it away: it stays linked,
    /// keeps its volume, and can be unmuted or detached later (detaching
    /// unmutes it). Placing video from the browser sets it when the
    /// browser is set to mute added sound.
    var soundMuted = false
    /// Where the clip is tied to a song on a Music layer, which it follows
    /// when the song moves; nil while no song is under it, and always on
    /// Music layers. See `followMusic(from:)`.
    var music: MusicAttachment?
    /// Off, the clip is never attached to the music and stays put when
    /// songs move.
    var followsMusic = true

    /// The length of the part of the source the clip plays. How long it lasts
    /// on the timeline is `placedDuration`, which differs when it is retimed.
    var trimmedDuration: CMTime {
        CMTimeSubtract(trimEnd, trimStart)
    }

    var endOffset: CMTime {
        CMTimeAdd(startOffset, placedDuration)
    }
}

/// Which streams of a media file a clip plays. A video with sound plays
/// both, linked, until its audio is detached: then the picture stays as a
/// `.video` clip and the sound moves to an `.audio` clip on its own layer.
enum ClipStreams: String {
    case videoAndAudio
    case video
    case audio
}

/// What a `TimelineClip` resolves to, for display and playback.
enum ResolvedClipInfo {
    case media(MediaClip)
    case timeline(Timeline)
    case adjustment
    case graphic

    var name: String {
        switch self {
        case .media(let clip): clip.name
        case .timeline(let timeline): timeline.name
        case .adjustment: "Adjustment"
        case .graphic: "Shapes"
        }
    }

    var systemImage: String {
        switch self {
        case .media(let clip): clip.kind.systemImage
        case .timeline: "rectangle.stack"
        case .adjustment: "slider.horizontal.below.rectangle"
        case .graphic: "square.on.circle"
        }
    }

    var summary: String {
        switch self {
        case .media(let clip): clip.formatSummary
        case .timeline(let timeline): "Nested Timeline · \(timeline.timebaseSummary)"
        case .adjustment: "Adjustment · applies its effects to the layers below"
        case .graphic: "Shapes · draws the shapes in its effects"
        }
    }

    var isVideo: Bool {
        switch self {
        case .media(let clip): clip.kind.hasPictures
        case .timeline(let timeline): !timeline.layers.isEmpty
        case .adjustment, .graphic: true
        }
    }

    var isHDR: Bool {
        switch self {
        case .media(let clip): clip.colorSpace.isHDR
        case .timeline(let timeline): timeline.colorSpace.isHDR
        case .adjustment, .graphic: false
        }
    }
}

struct MediaClip: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: MediaKind
    var url: URL?
    var duration: CMTime
    var frameRate: Double
    var colorSpace: ProjectColorSpace
    var codecName: String
    /// Whether the file has an audio track, which is what beat detection reads.
    /// True for audio files and for videos with sound.
    var hasAudio = false
    /// Hand-made changes to this asset's scene list. Detected cuts are not
    /// stored; they are recomputed from the saved change scores.
    var sceneEdits = SceneEdits()
    /// The beats as the person confirmed them, in original time. Detected
    /// beats are not stored here; they are a cache in the package.
    var beatMap = BeatMap()
    /// How much later a moment is in the current file than in the original:
    /// original time `t` is at `t + alignmentOffset` in the file. Trims,
    /// scenes and cuts stay in original time; this is added when reading.
    var alignmentOffset = CMTime.zero
    /// Files this asset used to point at, newest last. Only paths are kept,
    /// so a person can point the asset back at an earlier file.
    var previousPaths: [String] = []
    /// Size and modification time of the file when the project last accepted
    /// it. A different stamp on opening means it was swapped outside the app.
    var acceptedStamp: FileStamp?
    /// How long the original file was, kept when the asset is first
    /// replaced. The original's editing time stays `0..<originalDuration`:
    /// a longer replacement does not extend it, and a shorter one leaves
    /// part of it uncovered. Nil while the file is the original, and for
    /// assets replaced before it was kept.
    var originalDuration: CMTime?
    /// True once the person chose to forget the original. Its reference data
    /// is deleted at the next save and not captured again from whatever file
    /// is there now.
    var referenceForgotten = false

    /// True once the asset points at a file other than the one it was
    /// imported with, or at the same file realigned after it changed.
    var wasReplaced: Bool { !previousPaths.isEmpty || alignmentOffset != .zero }

    /// Where original time `time` is in the current file.
    func fileTime(forSourceTime time: CMTime) -> CMTime {
        CMTimeAdd(time, alignmentOffset)
    }

    var formatSummary: String {
        "\(kind.rawValue) · \(codecName) · \(colorSpace.rawValue)"
    }

    /// How long a still lasts when placed from the browser. It is a still's
    /// `duration`; its clips can then be trimmed to any length.
    static let stillLength = CMTime(value: 5, timescale: 1)
}

enum MediaKind: String, CaseIterable {
    case video = "Video"
    case audio = "Audio"
    /// A still picture (see docs/graphic-layers.md): no time of its own,
    /// so its clips can last as long as anyone wants.
    case image = "Image"

    var systemImage: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        }
    }

    /// Whether it has pictures to draw.
    var hasPictures: Bool { self != .audio }
}

enum ProjectColorSpace: String, CaseIterable, Identifiable {
    case rec709 = "Rec. 709"
    case rec2020PQ = "Rec. 2020 PQ HDR"
    case rec2020HLG = "Rec. 2020 HLG"

    var id: Self { self }

    var isHDR: Bool {
        switch self {
        case .rec709: false
        case .rec2020PQ, .rec2020HLG: true
        }
    }
}

extension CMTime {
    var formatted: String {
        guard isNumeric else { return "--:--" }
        let totalSeconds = max(0, seconds)
        let tenths = Int((totalSeconds * 10).rounded())
        return String(format: "%02ld:%02ld.%ld", (tenths / 10) / 60, (tenths / 10) % 60, tenths % 10)
    }

    /// hh:mm:ss:ff timecode using the given frame rate for the frames field.
    func timecode(frameRate: Double) -> String {
        guard isNumeric, frameRate > 0 else { return "00:00:00:00" }
        let totalSeconds = max(0, seconds)
        let framesPerSecond = max(1, Int(frameRate.rounded()))
        let totalFrames = Int((totalSeconds * frameRate).rounded())
        let frames = totalFrames % framesPerSecond
        let totalWholeSeconds = totalFrames / framesPerSecond
        let secs = totalWholeSeconds % 60
        let mins = (totalWholeSeconds / 60) % 60
        let hours = totalWholeSeconds / 3600
        return String(format: "%02d:%02d:%02d:%02d", hours, mins, secs, frames)
    }

    /// The same timecode with leading zero-valued fields dropped (always
    /// keeping at least seconds:frames) and the leftmost remaining field's
    /// own leading zero stripped — "00:00:05:00" -> "5:00",
    /// "00:12:05:00" -> "12:05:00".
    func compactTimecode(frameRate: Double) -> String {
        let parts = timecode(frameRate: frameRate).split(separator: ":").map(String.init)
        var startIndex = 0
        while startIndex < parts.count - 2 && parts[startIndex] == "00" {
            startIndex += 1
        }
        var kept = Array(parts[startIndex...])
        if let first = kept.first {
            kept[0] = String(Int(first) ?? 0)
        }
        return kept.joined(separator: ":")
    }
}
