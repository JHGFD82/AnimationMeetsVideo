import Testing
@testable import AnimationMeetsVideo

@Suite struct RulerTicksTests {
    @Test func stepsSplitASecondIntoWholeFrames() {
        #expect(RulerTicks.steps(framesPerSecond: 24).prefix(8) == [1, 2, 4, 6, 8, 12, 24, 48])
        #expect(RulerTicks.steps(framesPerSecond: 25).prefix(4) == [1, 5, 25, 50])
        #expect(RulerTicks.steps(framesPerSecond: 30).prefix(7) == [1, 2, 5, 6, 10, 15, 30])
    }

    @Test func labelsLeaveRoomAndTicksDivideThem() {
        // 24 fps at 20 points a frame: a label every 4 frames (80 points).
        let close = RulerTicks(frameRate: 24, pixelsPerFrame: 20)
        #expect(close.framesPerLabel == 4)
        #expect(close.framesPerMidTick == 2)
        #expect(close.framesPerTick == 1)

        // 24 fps at 5 points a frame: a half second per label, quarter
        // seconds between, a tick every 2 frames.
        let mid = RulerTicks(frameRate: 24, pixelsPerFrame: 5)
        #expect(mid.framesPerLabel == 24)
        #expect(mid.framesPerMidTick == 12)
        #expect(mid.framesPerTick == 2)
    }

    @Test func zoomedFarOutLabelsWholeSeconds() {
        // 24 fps at 2 points a second.
        let far = RulerTicks(frameRate: 24, pixelsPerFrame: 2.0 / 24)
        #expect(far.framesPerLabel == 60 * 24)
        #expect(far.framesPerLabel % far.framesPerTick == 0)
        #expect(far.level(ofFrame: 0) == .label)
    }
}
