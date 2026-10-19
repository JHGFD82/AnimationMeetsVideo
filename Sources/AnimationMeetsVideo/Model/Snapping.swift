import CoreMedia
import Foundation

/// Times in a timeline that dragged edges and the playhead snap to: clip
/// and section edges, the playhead, the start, and beat markers.
struct SnapTargets: Equatable {
    struct Target: Equatable {
        var time: CMTime
        /// The clip or section whose edge this is, so it doesn't snap to itself.
        var ownerID: UUID?
    }

    var targets: [Target]
    /// The playhead, read as a drag snaps rather than kept in `targets`.
    /// Timeline rows compare their targets to skip redrawing, and a
    /// playhead among them made every row redraw each time it moved. Not
    /// compared: the same object always reads where the playhead is now.
    var playhead: LivePlayhead?

    init(targets: [Target], playhead: LivePlayhead? = nil) {
        self.targets = targets
        self.playhead = playhead
    }

    static func == (lhs: SnapTargets, rhs: SnapTargets) -> Bool {
        lhs.targets == rhs.targets && lhs.playhead === rhs.playhead
    }

    /// The target nearest `time` no more than `tolerance` away, leaving out
    /// the edges of `excluding`.
    func nearest(to time: CMTime, within tolerance: CMTime, excluding ownerID: UUID? = nil) -> CMTime? {
        var best: (time: CMTime, distance: Double)?
        let live = playhead?.time.map { [Target(time: $0, ownerID: nil)] } ?? []
        for target in targets + live where ownerID == nil || target.ownerID != ownerID {
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
        excluding ownerID: UUID? = nil
    ) -> (start: CMTime, target: CMTime)? {
        let end = CMTimeAdd(start, duration)
        let byStart = nearest(to: start, within: tolerance, excluding: ownerID)
        let byEnd = nearest(to: end, within: tolerance, excluding: ownerID)
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

/// Where the playhead is, for snapping, kept where SwiftUI doesn't watch
/// it (see `SnapTargets.playhead`). Its owner brings it up to date as it
/// redraws.
final class LivePlayhead {
    var time: CMTime?
}

extension EditingProject {
    /// What edges and the playhead snap to in a timeline: its start, every
    /// clip's start and end on every layer, every section's, `playhead`
    /// when given, and `markers` (the beat markers shown). `live` is a
    /// playhead read as a drag snaps instead.
    func snapTargets(in timelineID: UUID, playhead: CMTime?, live: LivePlayhead? = nil, markers: [CMTime]) -> SnapTargets {
        var targets = [SnapTargets.Target(time: .zero, ownerID: nil)]
        let timeline = timeline(id: timelineID)
        for layer in timeline?.layers ?? [] {
            for clip in layer.clips {
                targets.append(SnapTargets.Target(time: clip.startOffset, ownerID: clip.id))
                targets.append(SnapTargets.Target(time: clip.endOffset, ownerID: clip.id))
            }
        }
        for section in timeline?.sections ?? [] {
            targets.append(SnapTargets.Target(time: section.start, ownerID: section.id))
            targets.append(SnapTargets.Target(time: section.end, ownerID: section.id))
        }
        if let playhead { targets.append(SnapTargets.Target(time: playhead, ownerID: nil)) }
        targets += markers.map { SnapTargets.Target(time: $0, ownerID: nil) }
        return SnapTargets(targets: targets, playhead: live)
    }
}
