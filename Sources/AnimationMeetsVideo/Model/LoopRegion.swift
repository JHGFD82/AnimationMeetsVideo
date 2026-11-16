import CoreMedia
import Foundation

/// A stretch of a timeline that playback repeats while it is on, as Logic
/// Pro's cycle range. One per timeline at most. It is view state, not
/// part of the project: changing it is no edit and adds no undo step. See
/// docs/loop-region.md.
struct LoopRegion: Equatable {
    var start: CMTime
    var end: CMTime
    var isOn = true

    enum Edge {
        case start, end
    }

    var duration: CMTime { CMTimeSubtract(end, start) }

    /// The shortest a region may be at a frame length: a quarter of a
    /// second, rounded up to whole frames (6 at 24 fps, 8 at 30). Shorter
    /// than that the player would do nothing but seek.
    static func minimumDuration(frameDuration frame: CMTime) -> CMTime {
        guard frame.isNumeric, frame.value > 0 else { return CMTime(value: 1, timescale: 4) }
        // A quarter second in frames is timescale / (4 * value), rounded up.
        let quarter = 4 * frame.value
        let frames = (Int64(frame.timescale) + quarter - 1) / quarter
        return CMTime(value: max(1, frames) * frame.value, timescale: frame.timescale)
    }
}

extension Timeline {
    /// The shortest a loop region may be on this timeline.
    var loopMinimumDuration: CMTime { LoopRegion.minimumDuration(frameDuration: frameDuration) }

    /// A region drawn from `anchor` to `other`, in either order: each end
    /// on its nearest frame and within `limits`. Nil when what is left is
    /// shorter than the minimum.
    func resolvedLoop(from anchor: CMTime, to other: CMTime, within limits: CMTimeRange) -> (start: CMTime, end: CMTime)? {
        guard anchor.isNumeric, other.isNumeric, let bounds = loopBounds(limits) else { return nil }
        let start = frameAligned(CMTimeMinimum(anchor, other), .nearest).clamped(between: bounds.start, and: bounds.end)
        let end = frameAligned(CMTimeMaximum(anchor, other), .nearest).clamped(between: bounds.start, and: bounds.end)
        guard CMTimeSubtract(end, start) >= loopMinimumDuration else { return nil }
        return (start, end)
    }

    /// The region with one edge dragged to `proposed`: on a frame, within
    /// `limits`, and never closer to the other edge than the minimum.
    func resolvedLoopEdge(_ region: LoopRegion, edge: LoopRegion.Edge, to proposed: CMTime, within limits: CMTimeRange) -> LoopRegion {
        guard proposed.isNumeric, let bounds = loopBounds(limits) else { return region }
        let time = frameAligned(proposed, .nearest)
        let minimum = loopMinimumDuration
        var resized = region
        switch edge {
        case .start:
            resized.start = CMTimeMinimum(CMTimeMaximum(time, bounds.start), CMTimeSubtract(region.end, minimum))
        case .end:
            resized.end = CMTimeMaximum(CMTimeMinimum(time, bounds.end), CMTimeAdd(region.start, minimum))
        }
        return resized
    }

    /// The region moved to start at `proposedStart`, its length kept: on a
    /// frame, and held inside `limits`. A region longer than the limits
    /// keeps its start at theirs and runs past their end.
    func resolvedLoopMove(_ region: LoopRegion, toStart proposedStart: CMTime, within limits: CMTimeRange) -> LoopRegion {
        guard proposedStart.isNumeric, let bounds = loopBounds(limits) else { return region }
        let latest = CMTimeSubtract(bounds.end, region.duration)
        let start = CMTimeMaximum(CMTimeMinimum(frameAligned(proposedStart, .nearest), latest), bounds.start)
        var moved = region
        moved.start = start
        moved.end = CMTimeAdd(start, region.duration)
        return moved
    }

    /// The frames inside `limits`: its start rounded up and its end down,
    /// so ends clamped to them stay on frames. Nil for limits that hold no
    /// whole frame or aren't numeric.
    private func loopBounds(_ limits: CMTimeRange) -> CMTimeRange? {
        guard limits.start.isNumeric, limits.end.isNumeric else { return nil }
        let start = frameAligned(limits.start, .up)
        let end = frameAligned(limits.end, .down)
        guard end > start else { return nil }
        return CMTimeRange(start: start, end: end)
    }
}
