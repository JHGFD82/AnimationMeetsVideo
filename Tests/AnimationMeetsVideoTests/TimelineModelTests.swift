import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private struct Fixture {
    var project = EditingProject.empty
    var timelineID: UUID
    var layerID: UUID
    var clipID: UUID

    /// A project whose root timeline holds one `duration`-second clip on one layer.
    init(duration: Double = 10) {
        timelineID = project.rootTimelineID
        let media = MediaClip(
            name: "Clip",
            kind: .video,
            url: nil,
            duration: seconds(duration),
            frameRate: 24,
            colorSpace: .rec709,
            codecName: "H.264"
        )
        let ids = project.importClip(media, intoTimeline: timelineID)!
        layerID = ids.layerID
        clipID = ids.clipID
    }

    var clips: [TimelineClip] {
        project.timeline(id: timelineID)!.layer(id: layerID)?.clips ?? []
    }

    var clip: TimelineClip { clips.first { $0.id == clipID }! }

    /// Adds a second clip to the same layer at `start`, `length` seconds long.
    mutating func addNeighbor(start: Double, length: Double) -> UUID {
        let neighbor = TimelineClip(
            source: clip.source,
            startOffset: seconds(start),
            trimStart: .zero,
            trimEnd: seconds(length)
        )
        let t = project.timelines.firstIndex { $0.id == timelineID }!
        let l = project.timelines[t].layers.firstIndex { $0.id == layerID }!
        project.timelines[t].layers[l].clips.append(neighbor)
        return neighbor.id
    }
}

@Suite struct SplitTests {
    @Test func splitsAtTimelineTimeWithoutIntroducingGap() {
        var f = Fixture()
        f.project.moveClip(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(5))
        f.project.split(f.clipID, in: f.timelineID, layer: f.layerID, atTimelineTime: seconds(8))

        #expect(f.clips.count == 2)
        let first = f.clips[0], second = f.clips[1]
        #expect(first.startOffset == seconds(5))
        #expect(first.trimEnd == seconds(3))
        #expect(second.startOffset == seconds(8))
        #expect(second.trimStart == seconds(3))
        #expect(second.trimEnd == seconds(10))
        #expect(first.endOffset == second.startOffset)
    }

    @Test func ignoresSplitOutsideClip() {
        var f = Fixture()
        f.project.split(f.clipID, in: f.timelineID, layer: f.layerID, atTimelineTime: seconds(10))
        f.project.split(f.clipID, in: f.timelineID, layer: f.layerID, atTimelineTime: .zero)
        #expect(f.clips.count == 1)
    }
}

@Suite struct DeleteTests {
    @Test func deletingLastClipRemovesLayer() {
        var f = Fixture()
        f.project.deleteClip(f.clipID, in: f.timelineID, layer: f.layerID)
        #expect(f.project.timeline(id: f.timelineID)!.layers.isEmpty)
    }

    @Test func deletingOneOfManyKeepsLayer() {
        var f = Fixture()
        _ = f.addNeighbor(start: 20, length: 2)
        f.project.deleteClip(f.clipID, in: f.timelineID, layer: f.layerID)
        #expect(f.clips.count == 1)
    }
}

@Suite struct MoveTests {
    @Test func clampsToZero() {
        var f = Fixture()
        f.project.moveClip(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(-3))
        #expect(f.clip.startOffset == .zero)
    }

    @Test func snapsToNearestFreeEdgeWhenOverlapping() {
        var f = Fixture(duration: 2)
        let neighbor = f.addNeighbor(start: 10, length: 4)
        // 2s clip dropped at 9 would overlap [10, 14); nearest free edge is 8.
        f.project.moveClip(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(9))
        #expect(f.clip.startOffset == seconds(8))
        #expect(f.clips.first { $0.id == neighbor }!.startOffset == seconds(10))
    }

    @Test func snapsAfterNeighborWhenCloserToItsEnd() {
        var f = Fixture(duration: 2)
        _ = f.addNeighbor(start: 10, length: 4)
        f.project.moveClip(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(13))
        #expect(f.clip.startOffset == seconds(14))
    }

    @Test func keepsClipsSortedByStart() {
        var f = Fixture(duration: 2)
        _ = f.addNeighbor(start: 5, length: 2)
        f.project.moveClip(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(20))
        #expect(f.clips.map(\.startOffset) == [seconds(5), seconds(20)])
    }
}

@Suite struct TrimTests {
    @Test func trimStartKeepsEndFixed() {
        var f = Fixture()
        f.project.moveClip(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(4))
        let endBefore = f.clip.endOffset
        f.project.trimClipStart(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(2))
        #expect(f.clip.trimStart == seconds(2))
        #expect(f.clip.startOffset == seconds(6))
        #expect(f.clip.endOffset == endBefore)
    }

    @Test func trimStartCannotRevealBeforeSourceStartOrCrossZero() {
        var f = Fixture()
        f.project.moveClip(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(1))
        f.project.trimClipStart(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(2))
        // Now trimStart 2, start 3. Dragging back past the source start clamps to 0.
        f.project.trimClipStart(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(-5))
        #expect(f.clip.trimStart == .zero)
        #expect(f.clip.startOffset >= .zero)
    }

    @Test func trimStartStopsAtPreviousClip() {
        var f = Fixture(duration: 10)
        f.project.moveClip(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(6))
        f.project.trimClipStart(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(5))
        _ = f.addNeighbor(start: 0, length: 4)
        // clip now covers [11, 16) with trimStart 5; previous ends at 4, so
        // the start can reach at most back to trimStart 5 - 7 -> clamped to 0.
        f.project.trimClipStart(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(0))
        let clip = f.clips.first { $0.id == f.clipID }!
        let previous = f.clips.first { $0.id != f.clipID }!
        #expect(clip.startOffset >= previous.endOffset)
    }

    @Test func trimEndBoundedBySourceDuration() {
        var f = Fixture()
        f.project.trimClipEnd(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(4))
        #expect(f.clip.trimEnd == seconds(4))
        f.project.trimClipEnd(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(99))
        #expect(f.clip.trimEnd == seconds(10))
    }

    @Test func trimEndKeepsMinimumDuration() {
        var f = Fixture()
        f.project.trimClipEnd(f.clipID, in: f.timelineID, layer: f.layerID, to: .zero)
        #expect(f.clip.trimmedDuration > .zero)
    }

    @Test func trimEndStopsAtNextClip() {
        var f = Fixture()
        f.project.trimClipEnd(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(3))
        _ = f.addNeighbor(start: 6, length: 2)
        f.project.trimClipEnd(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(10))
        #expect(f.clip.endOffset == seconds(6))
    }
}

@Suite struct EmbedTests {
    @Test func cannotEmbedSelfOrEmptyTimeline() {
        var f = Fixture()
        let other = f.project.addTimeline(name: "B", frameSize: CGSize(width: 1280, height: 720), frameRate: 24, colorSpace: .rec709)
        #expect(!f.project.canEmbed(f.timelineID, into: f.timelineID))
        #expect(!f.project.canEmbed(other, into: f.timelineID))
    }

    @Test func cannotCreateCycles() {
        var f = Fixture()
        let other = f.project.addTimeline(name: "B", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        #expect(f.project.embedTimeline(f.timelineID, intoTimeline: other) != nil)
        #expect(!f.project.canEmbed(other, into: f.timelineID))
        #expect(f.project.embedTimeline(other, intoTimeline: f.timelineID) == nil)
    }

    @Test func embedsNonEmptyTimelineOnNewTopLayer() {
        var f = Fixture()
        let other = f.project.addTimeline(name: "B", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        let ids = f.project.embedTimeline(f.timelineID, intoTimeline: other)
        #expect(ids != nil)
        #expect(f.project.timeline(id: other)!.layers.first?.id == ids?.layerID)
    }
}

@Suite struct TimeFormattingTests {
    @Test func timecodeUsesFrameRate() {
        #expect(seconds(1.5).timecode(frameRate: 24) == "00:00:01:12")
        #expect(seconds(3661).timecode(frameRate: 30) == "01:01:01:00")
    }

    @Test func timecodeHandlesInvalidInput() {
        #expect(CMTime.invalid.timecode(frameRate: 24) == "00:00:00:00")
        #expect(seconds(1).timecode(frameRate: 0) == "00:00:00:00")
    }

    @Test func compactTimecodeDropsLeadingZeroFields() {
        #expect(seconds(5).compactTimecode(frameRate: 24) == "5:00")
        #expect(seconds(12 * 60 + 5).compactTimecode(frameRate: 24) == "12:05:00")
    }

    @Test func formattedRoundsTenthsWithoutOverflow() {
        #expect(seconds(59.96).formatted == "01:00.0")
        #expect(seconds(75.3).formatted == "01:15.3")
        #expect(CMTime.invalid.formatted == "--:--")
    }
}

@Suite struct LayerOrderTests {
    @Test func movesLayerAndIgnoresOutOfRange() {
        var f = Fixture()
        let media = MediaClip(name: "B", kind: .video, url: nil, duration: seconds(3), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let second = f.project.importClip(media, intoTimeline: f.timelineID)!
        // Newest import is on top (index 0).
        #expect(f.project.timeline(id: f.timelineID)!.layers.first?.id == second.layerID)

        f.project.moveLayer(second.layerID, in: f.timelineID, by: -1)
        #expect(f.project.timeline(id: f.timelineID)!.layers.first?.id == second.layerID)

        f.project.moveLayer(second.layerID, in: f.timelineID, by: 1)
        #expect(f.project.timeline(id: f.timelineID)!.layers.last?.id == second.layerID)
    }
}
