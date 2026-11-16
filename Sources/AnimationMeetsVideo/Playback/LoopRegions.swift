import CoreMedia
import Foundation

/// The loop region of each timeline, kept the same in every player of the
/// project's windows: the project window's, a timeline window's, the
/// external display's own editor. Owned by `ProjectState`, which those
/// windows share. Each player's loop joins (`PlaybackLoop.shared`); a
/// change made through one is applied to the others showing the same
/// timeline, as if made there, so a playing one turns back as its own
/// change would have it. See docs/loop-region.md, "In every window".
///
/// What a timeline's region is, once any player has shown it, is kept
/// here; a window opening it later shows that, not what it last saved.
@MainActor
final class LoopRegions {
    private struct Member {
        weak var loop: PlaybackLoop?
    }

    private var members: [Member] = []
    /// Each timeline's region; a timeline in `known` without one has none.
    private var regions: [UUID: LoopRegion] = [:]
    private var known: Set<UUID> = []

    /// The region of `timelineID` as the project's players have it, or,
    /// the first time it is shown, `seed` (where the window showing it
    /// left it), which it then is.
    func region(of timelineID: UUID, seeding seed: LoopRegion?) -> LoopRegion? {
        if known.insert(timelineID).inserted { regions[timelineID] = seed }
        return regions[timelineID]
    }

    /// The region of `timelineID`, if a player has shown it.
    func region(of timelineID: UUID) -> LoopRegion? {
        regions[timelineID]
    }

    func join(_ loop: PlaybackLoop) {
        members.removeAll { $0.loop == nil }
        guard !members.contains(where: { $0.loop === loop }) else { return }
        members.append(Member(loop: loop))
    }

    func leave(_ loop: PlaybackLoop) {
        members.removeAll { $0.loop == nil || $0.loop === loop }
    }

    /// `loop` made `change` on `timelineID`, leaving it `region`: kept,
    /// and made in the other players showing that timeline.
    func changed(_ change: PlaybackLoop.Change, to region: LoopRegion?, in timelineID: UUID, by loop: PlaybackLoop) {
        known.insert(timelineID)
        regions[timelineID] = region
        members.removeAll { $0.loop == nil }
        for member in members {
            guard let other = member.loop, other !== loop, other.timelineID == timelineID else { continue }
            other.apply(change, publishing: false)
        }
    }
}
