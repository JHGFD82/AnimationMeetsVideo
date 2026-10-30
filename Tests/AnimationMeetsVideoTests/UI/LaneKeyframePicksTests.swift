import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Keyframes picked across the effects panel's lanes, and rows picked in
/// its stack.
@MainActor
@Suite struct LaneKeyframePicksTests {
    private func s(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    /// What the lanes were asked to do.
    @MainActor
    final class Edits {
        var moves: [ParameterKey: [CMTime: CMTime]] = [:]
        var deletes: [ParameterKey: [CMTime]] = [:]
    }

    /// Two lanes of a ten-second clip, 24 points a second: volume with
    /// keyframes at 1, 3 and 5 s on the top row, pan with 2 and 4 s under it.
    @MainActor
    private struct Fixture {
        let picks = LaneKeyframePicks()
        let edits = Edits()
        let volume: ParameterKey
        let pan: ParameterKey
    }

    private func fixture() -> Fixture {
        let project = EditingProject.empty
        let clip = TimelineClip(source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: s(10))
        let geometry = ClipLaneGeometry(clip: clip, timeline: project.timelines[0], width: 240)
        let volume = ParameterKey(timelineID: project.rootTimelineID, parameter: .clipVolume(clipID: clip.id))
        let pan = ParameterKey(timelineID: project.rootTimelineID, parameter: .clipPan(clipID: clip.id))
        let f = Fixture(volume: volume, pan: pan)
        for (row, (key, times)) in [(volume, [1.0, 3, 5]), (pan, [2.0, 4])].enumerated() {
            var edits = LaneKeyframeEdits { (_: @escaping (inout AnimatedValue<Double>) -> Void) in }
            edits.moveMany = { [edits = f.edits] moves in edits.moves[key] = moves }
            edits.delete = { [edits = f.edits] times in edits.deletes[key] = times }
            f.picks.register(key, times: times.map(s), geometry: geometry, edits: edits)
            f.picks.place(key, at: CGRect(x: 0, y: CGFloat(row) * 20, width: 240, height: 20))
        }
        return f
    }

    private func key(_ lane: ParameterKey, _ seconds: Double) -> LaneKeyframePicks.Key {
        LaneKeyframePicks.Key(lane: lane, time: s(seconds))
    }

    @Test func clicksPickAsEverywhereAndShiftPicksAcrossLanes() {
        let f = fixture()
        f.picks.click(key(f.volume, 1), .only)
        f.picks.click(key(f.pan, 4), .extend)
        #expect(f.picks.picked.items == [key(f.volume, 1), key(f.volume, 3), key(f.pan, 2), key(f.pan, 4)])
        f.picks.click(key(f.volume, 3), .toggle)
        #expect(!f.picks.contains(f.volume, s(3)))
    }

    @Test func aLassoPicksTheDiamondsItCovers() {
        let f = fixture()
        // From 2.5 s to 5.5 s, across both rows.
        f.picks.lasso(CGRect(x: 60, y: 0, width: 72, height: 40), keeping: [])
        #expect(f.picks.picked.items == [key(f.volume, 3), key(f.volume, 5), key(f.pan, 4)])
        #expect(f.picks.isNearKeyframe(CGPoint(x: 72, y: 10)))
        #expect(!f.picks.isNearKeyframe(CGPoint(x: 84, y: 10)))
    }

    @Test func pickedKeyframesMoveTogetherUpToTheirNeighbours() {
        let f = fixture()
        f.picks.click(key(f.volume, 3), .only)
        f.picks.click(key(f.pan, 4), .toggle)
        // Volume's 5 s keyframe isn't picked: they stop a frame short of it.
        let frame = f.picks.lanes[f.volume]!.geometry.timeline.frameDuration
        #expect(f.picks.allowedShift(s(5)) == CMTimeSubtract(s(2), frame))
        #expect(f.picks.drag(by: s(1)) == s(1))
        f.picks.endDrag(commit: true)
        #expect(f.edits.moves[f.volume] == [s(3): s(4)])
        #expect(f.edits.moves[f.pan] == [s(4): s(5)])
        #expect(f.picks.picked.items == [key(f.volume, 4), key(f.pan, 5)])
        #expect(f.picks.dragShift == nil)

        #expect(f.picks.deletePicked())
        #expect(f.edits.deletes[f.volume] == [s(4)])
        #expect(f.picks.isEmpty)
    }

    @Test func commandAPicksEveryKeyframeAndTheArrowsMoveThem() {
        let f = fixture()
        #expect(f.picks.selectAll())
        #expect(f.picks.picked.count == 5)
        f.picks.click(key(f.pan, 2), .only)
        let frame = f.picks.lanes[f.pan]!.geometry.timeline.frameDuration
        #expect(f.picks.nudge(frames: 1))
        #expect(f.edits.moves[f.pan] == [s(2): CMTimeAdd(s(2), frame)])
        #expect(f.picks.picked.items == [LaneKeyframePicks.Key(lane: f.pan, time: CMTimeAdd(s(2), frame))])
    }

    @Test func effectsAndControlsArePickedTogether() {
        let state = EffectsPanelState()
        let effect = UUID(), control = UUID(), other = UUID()
        let order = [effect, control, other]
        state.click(effect: effect, in: order, as: .only)
        state.click(effect: other, in: order, as: .extend)
        #expect(state.pickedRows.items == Set(order))
        #expect(state.picksSeveralRows)
        state.click(effect: effect, control: control, in: order, as: .toggle)
        #expect(!state.isPicked(control))
        state.select(effect: effect)
        #expect(state.pickedRows.items == [effect])
    }
}
