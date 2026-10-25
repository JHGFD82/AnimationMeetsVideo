import CoreMedia
import Foundation

// MARK: - Frame grid

extension Timeline {
    enum FrameRounding {
        case nearest, up, down
    }

    /// `time` moved onto this timeline's frame grid. Works in exact integer
    /// frame counts, so a time already on a frame stays exactly on it even
    /// at NTSC rates, where frame lengths aren't whole in any decimal unit.
    func frameAligned(_ time: CMTime, _ rounding: FrameRounding) -> CMTime {
        let frame = frameDuration
        guard time.isNumeric else { return .zero }
        let method: CMTimeRoundingMethod = switch rounding {
        case .nearest: .roundHalfAwayFromZero
        case .up: .roundTowardPositiveInfinity
        case .down: .roundTowardNegativeInfinity
        }
        let ticks = CMTimeConvertScale(time, timescale: frame.timescale, method: method).value
        let index: Int64 = switch rounding {
        case .down: Self.floorDivide(ticks, frame.value)
        case .up: -Self.floorDivide(-ticks, frame.value)
        case .nearest: Self.floorDivide(2 * ticks + frame.value, 2 * frame.value)
        }
        return CMTime(value: index * frame.value, timescale: frame.timescale)
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    /// Where a clip edge may sit. Clips with pictures stay on whole frames;
    /// audio is free to sit between them, down to `audioPlacementTimescale`.
    func placementTime(_ time: CMTime, _ rounding: FrameRounding, frameLocked: Bool) -> CMTime {
        if frameLocked { return frameAligned(time, rounding) }
        let method: CMTimeRoundingMethod = switch rounding {
        case .nearest: .roundHalfAwayFromZero
        case .up: .roundTowardPositiveInfinity
        case .down: .roundTowardNegativeInfinity
        }
        return CMTimeConvertScale(time, timescale: EditingProject.audioPlacementTimescale, method: method)
    }
}

// MARK: - Moving and trimming

extension EditingProject {
    /// How finely audio clips can be placed: one sample at 48 kHz.
    static let audioPlacementTimescale: CMTimeScale = 48_000

    /// Whether a clip's edges lock to the timeline's frames. Everything with
    /// pictures does, so a moved or trimmed clip never starts between two
    /// frames; only audio (including sound detached from a video) moves
    /// freely.
    func isFrameLocked(_ clip: TimelineClip) -> Bool {
        resolvedInfo(for: clip.source) == nil || playsVideo(clip)
    }

    /// The shortest a trim can make a clip: one frame for pictures, a
    /// twentieth of a second for audio.
    private func minimumDuration(of clip: TimelineClip, in timeline: Timeline) -> CMTime {
        isFrameLocked(clip) ? timeline.frameDuration : CMTime(value: 1, timescale: 20)
    }

    /// `clip` with its end trimmed back to cover a whole number of the
    /// timeline's frames, if it has pictures. Sources rarely last a whole
    /// number of frames at the timeline's rate, and a clip that doesn't
    /// ends between two frames, where no neighbor can meet it: placement
    /// rounds the neighbor onto the next frame, leaving a sliver of gap
    /// and no cut to join with a transition. Under a frame it is left alone.
    func coveringWholeFrames(_ clip: TimelineClip, in timeline: Timeline) -> TimelineClip {
        guard isFrameLocked(clip) else { return clip }
        // A retimed clip's length is found to a few microseconds, so one
        // meant to be a whole number of frames can come out just short of
        // it; that is the whole number, not a frame less, unless the
        // footage runs out first.
        let nearest = timeline.frameAligned(clip.placedDuration, .nearest)
        let isNearWhole = abs(CMTimeSubtract(clip.placedDuration, nearest).seconds) < Timeline.abutmentTolerance.seconds
        let lasting = clip.lasting(nearest)
        let fits = sourceDuration(for: clip.source).map { lasting.trimEnd <= $0 && lasting.trimStart >= .zero } ?? true
        let length = isNearWhole && fits ? nearest : timeline.frameAligned(clip.placedDuration, .down)
        guard length > .zero, length != clip.placedDuration else { return clip }
        return clip.lasting(length)
    }

    /// Trims every clip with pictures to whole frames, for projects saved
    /// before clips were created that way. See `coveringWholeFrames`.
    mutating func alignClipLengthsToFrames() {
        for t in timelines.indices {
            let timeline = timelines[t]
            for l in timeline.layers.indices {
                timelines[t].layers[l].clips = timeline.layers[l].clips.map { coveringWholeFrames($0, in: timeline) }
            }
        }
    }

    /// Puts what is on a timeline back on its frames, after its frame rate
    /// changed: the edges of clips with pictures (only the start of a
    /// retimed one), transition lengths, layer volume keyframes and sections
    /// each go to the nearest frame. Edges that met
    /// still meet, since they round alike. A clip keeps at least a frame
    /// and no more than its footage; a section keeps at least a frame and
    /// stays clear of the one before. Keyframes that land on one frame
    /// merge, keeping the later. Audio clips stay where they are.
    mutating func alignToFrames(timeline id: UUID) {
        guard let tIndex = timelines.firstIndex(id: id) else { return }
        let project = self
        let timeline = timelines[tIndex]
        let frame = timeline.frameDuration
        func nearest(_ time: CMTime) -> CMTime { CMTimeMaximum(.zero, timeline.frameAligned(time, .nearest)) }

        for lIndex in timeline.layers.indices {
            var layer = timeline.layers[lIndex]
            layer.clips = layer.clips.map { original in
                var clip = original
                if project.isFrameLocked(clip), clip.isRetimed {
                    // A retimed clip's length follows from its speed, so
                    // only its start moves.
                    clip.startOffset = nearest(clip.startOffset)
                } else if project.isFrameLocked(clip) {
                    let start = nearest(clip.startOffset)
                    var end = CMTimeMaximum(nearest(clip.endOffset), CMTimeAdd(start, frame))
                    if let length = project.sourceDuration(for: clip.source) {
                        let footage = timeline.frameAligned(CMTimeSubtract(length, clip.trimStart), .down)
                        end = CMTimeMinimum(end, CMTimeAdd(start, CMTimeMaximum(frame, footage)))
                    }
                    clip.startOffset = start
                    clip.trimEnd = CMTimeAdd(clip.trimStart, CMTimeSubtract(end, start))
                }
                for edge in [TransitionEdge.leading, .trailing] {
                    guard var transition = clip.transition(at: edge) else { continue }
                    transition.duration = CMTimeMaximum(frame, nearest(transition.duration))
                    transition.lead = CMTimeMinimum(nearest(transition.lead), transition.duration)
                    clip.setTransition(transition, at: edge)
                }
                return clip
            }
            // Clips' keyframes count in their source's time, which a new
            // rate doesn't change; a layer's volume and pan count in the
            // timeline's.
            layer.volume.moveKeyframeTimes(nearest)
            layer.pan.moveKeyframeTimes(nearest)
            timelines[tIndex].layers[lIndex] = layer
        }

        var previousEnd = CMTime.zero
        timelines[tIndex].sections = timeline.sections.map { original in
            var section = original
            section.start = CMTimeMaximum(nearest(section.start), previousEnd)
            section.end = CMTimeMaximum(nearest(section.end), CMTimeAdd(section.start, frame))
            previousEnd = section.end
            return section
        }
    }

    private func placementContext(_ id: UUID, in timelineID: UUID, layer layerID: UUID)
        -> (timeline: Timeline, clip: TimelineClip, others: [TimelineClip])?
    {
        guard let timeline = timeline(id: timelineID),
              let layer = timeline.layer(id: layerID),
              let clip = layer.clips.first(id: id)
        else {
            return nil
        }
        return (timeline, clip, layer.clips.filter { $0.id != id })
    }

    /// Where a clip asked to start at `proposedStart` lands, on its own
    /// layer or on `targetLayerID` (nil if that layer is the wrong kind for
    /// it), and what moves aside for it. It lands
    /// where it was dropped: never before zero, on a frame if it has
    /// pictures, and dropped inside another clip it goes to that clip's
    /// nearer edge, so a clip can go between two others or before the
    /// first. When it doesn't fit there, everything on the layer from the
    /// landing point on moves right just far enough to make room, keeping
    /// the gaps between those clips. The timeline shows this while
    /// dragging, so the drop lands where the clip was shown.
    func resolvedMove(
        ofMoving id: UUID,
        in timelineID: UUID,
        layer layerID: UUID,
        onto targetLayerID: UUID? = nil,
        to proposedStart: CMTime
    ) -> ClipMove? {
        guard let (timeline, moving, sameLayer) = placementContext(id, in: timelineID, layer: layerID) else { return nil }
        let others: [TimelineClip]
        if let targetLayerID, targetLayerID != layerID {
            guard let target = timeline.layer(id: targetLayerID), layer(target, accepts: moving) else { return nil }
            others = target.clips
        } else {
            others = sameLayer
        }
        return insertion(lasting: moving.placedDuration, frameLocked: isFrameLocked(moving), among: others, in: timeline, at: proposedStart)
    }

    /// Where something `length` long, asked to start at `proposedStart`,
    /// lands among `others` on a layer, and what moves aside for it, by the
    /// rule `resolvedMove` describes. Shared by moving a clip and by
    /// dropping media from the browser, so both land alike.
    func insertion(
        lasting length: CMTime, frameLocked locked: Bool, among others: [TimelineClip], in timeline: Timeline, at proposedStart: CMTime
    ) -> ClipMove {
        var start = timeline.placementTime(CMTimeMaximum(.zero, proposedStart), .nearest, frameLocked: locked)
        if let under = others.first(where: { $0.startOffset < start && start < $0.endOffset }) {
            let toStart = CMTimeSubtract(start, under.startOffset)
            let toEnd = CMTimeSubtract(under.endOffset, start)
            start = toStart < toEnd
                ? under.startOffset
                : timeline.placementTime(under.endOffset, .up, frameLocked: locked)
        }
        let followers = others.filter { $0.startOffset >= start }
        guard let next = followers.map(\.startOffset).min() else {
            return ClipMove(start: start, pushFrom: start, push: .zero)
        }
        var push = CMTimeMaximum(.zero, CMTimeSubtract(CMTimeAdd(start, length), next))
        // Pushed clips with pictures must stay on frames.
        if push > .zero, followers.contains(where: isFrameLocked) {
            push = timeline.frameAligned(push, .up)
        }
        return ClipMove(start: start, pushFrom: start, push: push)
    }

    /// Where a moved clip lands; see `resolvedMove`.
    func resolvedStart(
        ofMoving id: UUID,
        in timelineID: UUID,
        layer layerID: UUID,
        onto targetLayerID: UUID? = nil,
        to proposedStart: CMTime
    ) -> CMTime? {
        resolvedMove(ofMoving: id, in: timelineID, layer: layerID, onto: targetLayerID, to: proposedStart)?.start
    }

    /// The nearest start to `proposedStart` where `clip` fits among `others`
    /// on the timeline's grid, or nil if there is no gap big enough.
    func freeStart(for moving: TimelineClip, among others: [TimelineClip], in timeline: Timeline, near proposedStart: CMTime) -> CMTime? {
        let locked = isFrameLocked(moving)
        let length = moving.placedDuration
        var candidate = timeline.placementTime(CMTimeMaximum(.zero, proposedStart), .nearest, frameLocked: locked)

        for _ in 0...others.count {
            guard let blocker = others.first(where: { candidate < $0.endOffset && CMTimeAdd(candidate, length) > $0.startOffset }) else {
                return candidate
            }
            let before = timeline.placementTime(CMTimeSubtract(blocker.startOffset, length), .down, frameLocked: locked)
            let after = timeline.placementTime(blocker.endOffset, .up, frameLocked: locked)
            if before >= .zero,
               CMTimeAbsoluteValue(CMTimeSubtract(candidate, before)) < CMTimeAbsoluteValue(CMTimeSubtract(candidate, after)) {
                candidate = before
            } else {
                candidate = after
            }
        }
        return nil
    }

    /// The clip after dragging its leading edge toward `proposedTrimStart`.
    /// The clip's end stays put while its start follows the trim: it can't
    /// reveal frames before the source's own start, cross zero, run into
    /// the previous clip, or shrink below the minimum length. Given the
    /// assets' scores, it also can't reach into the scene before the one
    /// its first frame is in (see `trimFootage(of:sceneTracks:)`).
    func resolvedTrimStart(
        of id: UUID, in timelineID: UUID, layer layerID: UUID, to proposedTrimStart: CMTime,
        sceneTracks: [UUID: ChangeScoreTrack]? = nil
    ) -> TimelineClip? {
        guard let (timeline, clip, others) = placementContext(id, in: timelineID, layer: layerID) else { return nil }
        let locked = isFrameLocked(clip)
        // Where the source's own start would play, on the timeline.
        // (Backwards, the leading edge is the end of the trim.)
        var lowest = CMTimeMaximum(.zero, clip.timelineTime(forSourceTime: clip.isReversed ? (sourceDuration(for: clip.source) ?? clip.trimEnd) : .zero))
        if let footage = trimFootage(of: clip, sceneTracks: sceneTracks) {
            lowest = CMTimeMaximum(lowest, clip.timelineTime(forSourceTime: clip.isReversed ? footage.end : footage.start))
        }
        if let previousEnd = others.filter({ $0.endOffset <= clip.startOffset }).map(\.endOffset).max() {
            lowest = CMTimeMaximum(lowest, previousEnd)
        }
        let highest = CMTimeSubtract(clip.endOffset, minimumDuration(of: clip, in: timeline))
        let lower = timeline.placementTime(lowest, .up, frameLocked: locked)
        let upper = timeline.placementTime(highest, .down, frameLocked: locked)
        guard upper >= lower else { return nil }

        let proposedStart = clip.timelineTime(forSourceTime: proposedTrimStart)
        let start = timeline.placementTime(proposedStart, .nearest, frameLocked: locked)
        let newStart = CMTimeMinimum(CMTimeMaximum(start, lower), upper)
        var trimmed = clip
        let source = clip.sourceTime(atTimelineTime: newStart)
        if clip.isReversed { trimmed.trimEnd = source } else { trimmed.trimStart = source }
        trimmed.startOffset = newStart
        return trimmed
    }

    /// The clip after dragging its trailing edge toward `proposedTrimEnd`.
    /// The start stays put; the end is bounded by the source's length, the
    /// next clip and the minimum length, and given the assets' scores, by
    /// the end of the scene its last frame is in.
    func resolvedTrimEnd(
        of id: UUID, in timelineID: UUID, layer layerID: UUID, to proposedTrimEnd: CMTime,
        sceneTracks: [UUID: ChangeScoreTrack]? = nil
    ) -> TimelineClip? {
        guard let (timeline, clip, others) = placementContext(id, in: timelineID, layer: layerID),
              let sourceDuration = sourceDuration(for: clip.source)
        else {
            return nil
        }
        let locked = isFrameLocked(clip)
        // Where the end of the source would play, on the timeline.
        var highest = clip.timelineTime(forSourceTime: clip.isReversed ? .zero : sourceDuration)
        if let footage = trimFootage(of: clip, sceneTracks: sceneTracks) {
            highest = CMTimeMinimum(highest, clip.timelineTime(forSourceTime: clip.isReversed ? footage.start : footage.end))
        }
        if let nextStart = others.filter({ $0.startOffset >= clip.endOffset }).map(\.startOffset).min() {
            highest = CMTimeMinimum(highest, nextStart)
        }
        let lowest = CMTimeAdd(clip.startOffset, minimumDuration(of: clip, in: timeline))
        let lower = timeline.placementTime(lowest, .up, frameLocked: locked)
        let upper = timeline.placementTime(highest, .down, frameLocked: locked)
        guard upper >= lower else { return nil }

        let proposedEnd = clip.timelineTime(forSourceTime: proposedTrimEnd)
        let end = timeline.placementTime(proposedEnd, .nearest, frameLocked: locked)
        let newEnd = CMTimeMinimum(CMTimeMaximum(end, lower), upper)
        var trimmed = clip
        let source = clip.sourceTime(atTimelineTime: newEnd)
        if clip.isReversed { trimmed.trimStart = source } else { trimmed.trimEnd = source }
        return trimmed
    }

    /// The footage a trim of the clip's picture keeps to: from the start of
    /// the scene its first frame is in to the end of the scene its last
    /// frame is in, so an edge stops at a cut rather than running on into
    /// the next shot. Nil without `sceneTracks` (the scores by asset), and
    /// for sound taken off on its own, which has no picture edge to keep
    /// to. An asset whose scores aren't in yet is still held to the cuts
    /// made by hand.
    func trimFootage(of clip: TimelineClip, sceneTracks: [UUID: ChangeScoreTrack]?) -> CMTimeRange? {
        guard let sceneTracks, clip.streams != .audio, case .media(let id) = clip.source else { return nil }
        return sceneFootage(of: clip, track: sceneTracks[id])
    }

    /// The clip after slipping its footage by `proposedDelta` (positive plays
    /// later footage): its start and end stay where they are and the part
    /// of the source it plays moves. Where the file runs out the footage
    /// stops at the file's start or end and the clip gets shorter from its
    /// end instead, down to the minimum length; `slipClip` then moves the
    /// clips after it in by as much. Video slips by whole frames.
    func resolvedSlip(of id: UUID, in timelineID: UUID, layer layerID: UUID, by proposedDelta: CMTime) -> TimelineClip? {
        guard let (timeline, clip, _) = placementContext(id, in: timelineID, layer: layerID),
              let sourceDuration = sourceDuration(for: clip.source)
        else {
            return nil
        }
        let locked = isFrameLocked(clip)
        // The drag is in timeline time; a retimed clip's footage moves by
        // more or less than that.
        let delta = clip.sourceDelta(forPlacedDelta: locked ? timeline.frameAligned(proposedDelta, .nearest) : proposedDelta)
        let minimum = clip.isRetimed ? clip.sourceDuration(forPlaced: minimumDuration(of: clip, in: timeline)) : minimumDuration(of: clip, in: timeline)
        var start = CMTimeAdd(clip.trimStart, delta)
        var end = CMTimeAdd(clip.trimEnd, delta)
        if start < .zero { start = .zero }
        if end > sourceDuration { end = sourceDuration }
        // Out of footage on both sides at once only when the slip runs
        // past the minimum length: keep the minimum against the file edge.
        if CMTimeSubtract(end, start) < minimum {
            if delta > .zero {
                start = CMTimeMaximum(.zero, CMTimeSubtract(sourceDuration, minimum))
                end = CMTimeAdd(start, minimum)
            } else {
                start = .zero
                end = CMTimeMinimum(sourceDuration, minimum)
            }
        }
        // A shortened clip stays a whole number of frames, kept against the
        // file edge it ran into.
        var length = CMTimeSubtract(end, start)
        if locked, !clip.isRetimed, length != clip.trimmedDuration {
            length = CMTimeMaximum(minimum, timeline.frameAligned(length, .down))
            if start == .zero { end = CMTimeAdd(start, length) } else { start = CMTimeSubtract(end, length) }
        }
        var slipped = clip
        slipped.trimStart = start
        slipped.trimEnd = end
        return slipped
    }

    /// The length of a source with no footage to run out of (a still, an
    /// adjustment or shapes): as long as anyone would want.
    static let unboundedLength = CMTime(value: 36_000, timescale: 1)

    func sourceDuration(for source: ClipSource) -> CMTime? {
        switch resolvedInfo(for: source) {
        case .media(let clip) where clip.kind == .image: Self.unboundedLength
        case .media(let clip): clip.duration
        case .timeline(let timeline): timeline.duration
        case .adjustment, .graphic: Self.unboundedLength
        case nil: nil
        }
    }
}

/// A clip moving right to make room for one dragged in front of it.
struct PushedClip: Equatable {
    var from: CMTime
    var to: CMTime
}

/// How a clip move resolves: where the clip starts, and how far the clips
/// on its new layer starting at or after `pushFrom` move right for it.
struct ClipMove: Equatable {
    var start: CMTime
    var pushFrom: CMTime
    var push: CMTime
}

extension [TimelineClip] {
    /// Moves every clip that starts at or after `move.pushFrom` right by
    /// `move.push`, to make room for what `move` places.
    mutating func makeRoom(for move: ClipMove) {
        guard move.push > .zero else { return }
        for index in indices where self[index].startOffset >= move.pushFrom {
            self[index].startOffset = CMTimeAdd(self[index].startOffset, move.push)
        }
    }
}
