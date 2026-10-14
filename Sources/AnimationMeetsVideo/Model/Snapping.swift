import CoreMedia
import Foundation

/// Times in a timeline that dragged edges and the playhead snap to: clip
/// edges on every layer, the playhead, the start, and beat markers.
struct SnapTargets: Equatable {
    struct Target: Equatable {
        var time: CMTime
        /// The clip whose edge this is, so a clip doesn't snap to itself.
        var clipID: UUID?
    }

    var targets: [Target]

    /// The target nearest `time` no more than `tolerance` away, leaving out
    /// the edges of `excluding`.
    func nearest(to time: CMTime, within tolerance: CMTime, excluding clipID: UUID? = nil) -> CMTime? {
        var best: (time: CMTime, distance: Double)?
        for target in targets where clipID == nil || target.clipID != clipID {
            let distance = abs(CMTimeSubtract(target.time, time).seconds)
            guard distance <= tolerance.seconds, distance < (best?.distance ?? .infinity) else { continue }
            best = (target.time, distance)
        }
        return best?.time
    }

    /// Where a span of `duration` starting at `start` lands when whichever
    /// of its ends is nearer a target snaps to it, and that target.
    func snappedStart(
        _ start: CMTime,
        duration: CMTime,
        within tolerance: CMTime,
        excluding clipID: UUID? = nil
    ) -> (start: CMTime, target: CMTime)? {
        let end = CMTimeAdd(start, duration)
        let byStart = nearest(to: start, within: tolerance, excluding: clipID)
        let byEnd = nearest(to: end, within: tolerance, excluding: clipID)
        let startDistance = byStart.map { abs(CMTimeSubtract($0, start).seconds) } ?? .infinity
        let endDistance = byEnd.map { abs(CMTimeSubtract($0, end).seconds) } ?? .infinity
        if let byStart, startDistance <= endDistance {
            return (byStart, byStart)
        }
        if let byEnd {
            return (CMTimeMaximum(.zero, CMTimeSubtract(byEnd, duration)), byEnd)
        }
        return nil
    }
}

extension EditingProject {
    /// What edges and the playhead snap to in a timeline: its start, every
    /// clip's start and end on every layer, `playhead` when given, and
    /// `markers` (the beat markers shown).
    func snapTargets(in timelineID: UUID, playhead: CMTime?, markers: [CMTime]) -> SnapTargets {
        var targets = [SnapTargets.Target(time: .zero, clipID: nil)]
        for layer in timeline(id: timelineID)?.layers ?? [] {
            for clip in layer.clips {
                targets.append(SnapTargets.Target(time: clip.startOffset, clipID: clip.id))
                targets.append(SnapTargets.Target(time: clip.endOffset, clipID: clip.id))
            }
        }
        if let playhead { targets.append(SnapTargets.Target(time: playhead, clipID: nil)) }
        targets += markers.map { SnapTargets.Target(time: $0, clipID: nil) }
        return SnapTargets(targets: targets)
    }
}
