import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

/// Where a loop region may be (docs/loop-region.md, "Model").
@Suite struct LoopRegionTests {
    private func timeline(frameRate: Double = 24) -> Timeline {
        var project = EditingProject.empty
        project.timelines[0].frameRate = frameRate
        return project.timelines[0]
    }

    private let everything = CMTimeRange(start: .zero, end: CMTime(value: 60, timescale: 1))

    @Test func theMinimumIsAQuarterSecondInWholeFrames() {
        #expect(timeline(frameRate: 24).loopMinimumDuration == CMTime(value: 6, timescale: 24))
        #expect(timeline(frameRate: 30).loopMinimumDuration == CMTime(value: 8, timescale: 30))
        // 23.976: a quarter second is 5.994 frames.
        #expect(timeline(frameRate: 23.976).loopMinimumDuration == CMTime(value: 6 * 1001, timescale: 24000))
        #expect(timeline(frameRate: 12.5).loopMinimumDuration == CMTime(value: 4 * 1000, timescale: 12500))
    }

    @Test func drawingRightToLeftOrdersTheEndsOnFrames() throws {
        let t = timeline()
        let drawn = try #require(t.resolvedLoop(from: seconds(4.02), to: seconds(2.01), within: everything))
        #expect(drawn.start == CMTime(value: 48, timescale: 24))
        #expect(drawn.end == CMTime(value: 96, timescale: 24))
    }

    @Test func endsLandOnFramesAtNTSCRates() throws {
        let t = timeline(frameRate: 23.976)
        let frame = t.frameDuration
        let drawn = try #require(t.resolvedLoop(from: seconds(1), to: seconds(3), within: everything))
        #expect(drawn.start.timescale == frame.timescale && drawn.start.value % frame.value == 0)
        #expect(drawn.end.timescale == frame.timescale && drawn.end.value % frame.value == 0)
        #expect(t.frameAligned(drawn.start, .nearest) == drawn.start)

        let thirty = timeline(frameRate: 30)
        let other = try #require(thirty.resolvedLoop(from: seconds(1.01), to: seconds(2), within: everything))
        #expect(other.start == CMTime(value: 30, timescale: 30))
    }

    @Test func tooShortMakesNothing() {
        let t = timeline()
        #expect(t.resolvedLoop(from: seconds(1), to: CMTime(value: 29, timescale: 24), within: everything) == nil)
        #expect(t.resolvedLoop(from: seconds(1), to: CMTime(value: 30, timescale: 24), within: everything) != nil)
    }

    @Test func drawingIsHeldInsideTheLimits() throws {
        let t = timeline()
        let limits = CMTimeRange(start: seconds(2), end: seconds(10))
        let drawn = try #require(t.resolvedLoop(from: seconds(0), to: seconds(30), within: limits))
        #expect(drawn.start == seconds(2) && drawn.end == seconds(10))
        // Wholly outside, what is left is too short.
        #expect(t.resolvedLoop(from: seconds(11), to: seconds(20), within: limits) == nil)
        // A limit between frames: the ends stay on frames inside it.
        let ragged = CMTimeRange(start: seconds(2.01), end: seconds(9.99))
        let inside = try #require(t.resolvedLoop(from: seconds(0), to: seconds(30), within: ragged))
        #expect(inside.start == CMTime(value: 49, timescale: 24))
        #expect(inside.end == CMTime(value: 239, timescale: 24))
    }

    @Test func anEdgeStopsAtTheMinimumAndAtALimit() {
        let t = timeline()
        let region = LoopRegion(start: seconds(4), end: seconds(8))
        let limits = CMTimeRange(start: seconds(2), end: seconds(10))

        #expect(t.resolvedLoopEdge(region, edge: .start, to: seconds(3), within: limits).start == seconds(3))
        #expect(t.resolvedLoopEdge(region, edge: .start, to: seconds(0), within: limits).start == seconds(2))
        #expect(t.resolvedLoopEdge(region, edge: .start, to: seconds(9), within: limits).start == seconds(7.75))
        #expect(t.resolvedLoopEdge(region, edge: .end, to: seconds(20), within: limits).end == seconds(10))
        #expect(t.resolvedLoopEdge(region, edge: .end, to: seconds(1), within: limits).end == seconds(4.25))
        // The other edge never moves.
        #expect(t.resolvedLoopEdge(region, edge: .end, to: seconds(9), within: limits).start == seconds(4))
    }

    @Test func aMoveKeepsTheLengthInsideTheLimits() {
        let t = timeline()
        let region = LoopRegion(start: seconds(4), end: seconds(8), isOn: false)
        let limits = CMTimeRange(start: seconds(2), end: seconds(10))

        let moved = t.resolvedLoopMove(region, toStart: seconds(5.01), within: limits)
        #expect(moved.start == seconds(5) && moved.end == seconds(9))
        #expect(!moved.isOn)
        let late = t.resolvedLoopMove(region, toStart: seconds(9), within: limits)
        #expect(late.start == seconds(6) && late.end == seconds(10))
        let early = t.resolvedLoopMove(region, toStart: seconds(-3), within: limits)
        #expect(early.start == seconds(2) && early.end == seconds(6))
    }

    @Test func aRegionLongerThanTheLimitsKeepsItsStartAtTheirs() {
        let t = timeline()
        let region = LoopRegion(start: seconds(0), end: seconds(20))
        let limits = CMTimeRange(start: seconds(2), end: seconds(10))
        let moved = t.resolvedLoopMove(region, toStart: seconds(5), within: limits)
        #expect(moved.start == seconds(2) && moved.duration == seconds(20))
    }
}
