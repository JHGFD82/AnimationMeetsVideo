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
        let length = timeline.frameAligned(clip.trimmedDuration, .down)
        guard length > .zero, length != clip.trimmedDuration else { return clip }
        var aligned = clip
        aligned.trimEnd = CMTimeAdd(clip.trimStart, length)
        return aligned
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

    private func placementContext(_ id: UUID, in timelineID: UUID, layer layerID: UUID)
        -> (timeline: Timeline, clip: TimelineClip, others: [TimelineClip])?
    {
        guard let timeline = timeline(id: timelineID),
              let layer = timeline.layer(id: layerID),
              let clip = layer.clips.first(where: { $0.id == id })
        else {
            return nil
        }
        return (timeline, clip, layer.clips.filter { $0.id != id })
    }

    /// Where a clip asked to start at `proposedStart` actually lands: never
    /// before zero, on a frame if it has pictures, and never overlapping
    /// another clip on its layer — or on `targetLayerID` when it is moving
    /// to another layer. A drop onto a neighbor goes to the nearest free
    /// edge; nil means the layer has no gap big enough. The timeline shows
    /// this while dragging, so the drop lands where the clip was shown.
    func resolvedStart(
        ofMoving id: UUID,
        in timelineID: UUID,
        layer layerID: UUID,
        onto targetLayerID: UUID? = nil,
        to proposedStart: CMTime
    ) -> CMTime? {
        guard let (timeline, moving, sameLayer) = placementContext(id, in: timelineID, layer: layerID) else { return nil }
        let others: [TimelineClip]
        if let targetLayerID, targetLayerID != layerID {
            guard let target = timeline.layer(id: targetLayerID) else { return nil }
            others = target.clips
        } else {
            others = sameLayer
        }
        return freeStart(for: moving, among: others, in: timeline, near: proposedStart)
    }

    /// The nearest start to `proposedStart` where `clip` fits among `others`
    /// on the timeline's grid, or nil if there is no gap big enough.
    func freeStart(for moving: TimelineClip, among others: [TimelineClip], in timeline: Timeline, near proposedStart: CMTime) -> CMTime? {
        let locked = isFrameLocked(moving)
        let length = moving.trimmedDuration
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
    /// the previous clip, or shrink below the minimum length.
    func resolvedTrimStart(of id: UUID, in timelineID: UUID, layer layerID: UUID, to proposedTrimStart: CMTime) -> TimelineClip? {
        guard let (timeline, clip, others) = placementContext(id, in: timelineID, layer: layerID) else { return nil }
        let locked = isFrameLocked(clip)
        var lowest = CMTimeMaximum(.zero, CMTimeSubtract(clip.startOffset, clip.trimStart))
        if let previousEnd = others.filter({ $0.endOffset <= clip.startOffset }).map(\.endOffset).max() {
            lowest = CMTimeMaximum(lowest, previousEnd)
        }
        let highest = CMTimeSubtract(clip.endOffset, minimumDuration(of: clip, in: timeline))
        let lower = timeline.placementTime(lowest, .up, frameLocked: locked)
        let upper = timeline.placementTime(highest, .down, frameLocked: locked)
        guard upper >= lower else { return nil }

        let proposedStart = CMTimeAdd(clip.startOffset, CMTimeSubtract(proposedTrimStart, clip.trimStart))
        let start = timeline.placementTime(proposedStart, .nearest, frameLocked: locked)
        let newStart = CMTimeMinimum(CMTimeMaximum(start, lower), upper)
        var trimmed = clip
        trimmed.trimStart = CMTimeAdd(clip.trimStart, CMTimeSubtract(newStart, clip.startOffset))
        trimmed.startOffset = newStart
        return trimmed
    }

    /// The clip after dragging its trailing edge toward `proposedTrimEnd`.
    /// The start stays put; the end is bounded by the source's length, the
    /// next clip and the minimum length.
    func resolvedTrimEnd(of id: UUID, in timelineID: UUID, layer layerID: UUID, to proposedTrimEnd: CMTime) -> TimelineClip? {
        guard let (timeline, clip, others) = placementContext(id, in: timelineID, layer: layerID),
              let sourceDuration = sourceDuration(for: clip.source)
        else {
            return nil
        }
        let locked = isFrameLocked(clip)
        var highest = CMTimeAdd(clip.startOffset, CMTimeSubtract(sourceDuration, clip.trimStart))
        if let nextStart = others.filter({ $0.startOffset >= clip.endOffset }).map(\.startOffset).min() {
            highest = CMTimeMinimum(highest, nextStart)
        }
        let lowest = CMTimeAdd(clip.startOffset, minimumDuration(of: clip, in: timeline))
        let lower = timeline.placementTime(lowest, .up, frameLocked: locked)
        let upper = timeline.placementTime(highest, .down, frameLocked: locked)
        guard upper >= lower else { return nil }

        let proposedEnd = CMTimeAdd(clip.startOffset, CMTimeSubtract(proposedTrimEnd, clip.trimStart))
        let end = timeline.placementTime(proposedEnd, .nearest, frameLocked: locked)
        let newEnd = CMTimeMinimum(CMTimeMaximum(end, lower), upper)
        var trimmed = clip
        trimmed.trimEnd = CMTimeAdd(clip.trimStart, CMTimeSubtract(newEnd, clip.startOffset))
        return trimmed
    }

    func sourceDuration(for source: ClipSource) -> CMTime? {
        switch resolvedInfo(for: source) {
        case .media(let clip): clip.duration
        case .timeline(let timeline): timeline.duration
        case nil: nil
        }
    }
}
