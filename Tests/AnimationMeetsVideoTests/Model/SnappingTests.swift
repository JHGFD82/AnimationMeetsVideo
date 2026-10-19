import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

@Suite struct SnappingTests {
    private let clipA = UUID()
    private let clipB = UUID()

    private var targets: SnapTargets {
        SnapTargets(targets: [
            .init(time: .zero, ownerID: nil),
            .init(time: seconds(2), ownerID: clipA),
            .init(time: seconds(5), ownerID: clipA),
            .init(time: seconds(8), ownerID: clipB),
            .init(time: seconds(6), ownerID: nil),
        ])
    }

    @Test func snapsToTheNearestTargetWithinTheTolerance() {
        #expect(targets.nearest(to: seconds(5.2), within: seconds(0.3)) == seconds(5))
        #expect(targets.nearest(to: seconds(5.6), within: seconds(0.5)) == seconds(6))
        #expect(targets.nearest(to: seconds(3.5), within: seconds(0.3)) == nil)
    }

    @Test func aClipDoesNotSnapToItsOwnEdges() {
        #expect(targets.nearest(to: seconds(2.1), within: seconds(0.3), excluding: clipA) == nil)
        #expect(targets.nearest(to: seconds(7.9), within: seconds(0.3), excluding: clipA) == seconds(8))
    }

    @Test func aMovedSpanSnapsByWhicheverEndIsNearer() {
        let byStart = targets.snappedStart(seconds(2.2), duration: seconds(1), within: seconds(0.3))
        #expect(byStart?.start == seconds(2) && byStart?.target == seconds(2))
        // Start 0.3 s from 2, end 0.1 s from 8: the end wins.
        let byEnd = targets.snappedStart(seconds(1.7), duration: seconds(6.2), within: seconds(0.3))
        #expect(byEnd?.target == seconds(8))
        #expect(byEnd?.start == seconds(1.8))
        #expect(targets.snappedStart(seconds(3.4), duration: seconds(1), within: seconds(0.3)) == nil)
        #expect(targets.snappedStart(seconds(2.1), duration: seconds(1), within: seconds(0.3), excluding: clipA) == nil)
    }

    @Test func targetsComeFromEveryLayerThePlayheadAndMarkers() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let media = MediaClip(name: "Clip", kind: .video, url: nil, duration: seconds(4), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        _ = project.importClip(media, intoTimeline: t)
        let placed = project.importClip(media, intoTimeline: t)
        let second = try #require(placed)
        project.moveClip(second.clipID, in: t, layer: second.layerID, to: seconds(10))

        let times = Set(project.snapTargets(in: t, playhead: seconds(7), markers: [seconds(1.5)]).targets.map(\.time.seconds))

        #expect(times == [0, 4, 10, 14, 7, 1.5])
    }

    /// A live playhead is snapped to where it is when asked, and moving it
    /// doesn't make the targets compare as changed, so timeline rows aren't
    /// redrawn as the playhead moves.
    @Test func aLivePlayheadSnapsWhereItIsNowWithoutChangingTheTargets() {
        let playhead = LivePlayhead()
        playhead.time = seconds(3)
        let before = SnapTargets(targets: targets.targets, playhead: playhead)
        #expect(before.nearest(to: seconds(3.1), within: seconds(0.3)) == seconds(3))

        playhead.time = seconds(4)
        let after = SnapTargets(targets: targets.targets, playhead: playhead)
        #expect(before == after)
        #expect(before.nearest(to: seconds(3.1), within: seconds(0.3)) == nil)
        #expect(before.nearest(to: seconds(4.2), within: seconds(0.3)) == seconds(4))
        #expect(before != SnapTargets(targets: targets.targets, playhead: LivePlayhead()))
    }
}
