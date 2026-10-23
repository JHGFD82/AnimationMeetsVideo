import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private let frame = CMTime(value: 1, timescale: 24)

/// Feedback, Slit-Scan and Flow Smear drawn from synthetic pictures: track 1
/// is the clip's footage now, track 2 the same footage a frame earlier.
@Suite struct MomentLookTests {
    private func clip(_ effects: [Effect], moments: [TrackCopy] = [], ahead: TrackCopy? = nil) -> DrawClip {
        var media = MediaDraw(
            trackID: 1, base: .identity, url: URL(fileURLWithPath: "/dev/null"), sourceStart: .zero, segmentStart: .zero,
            frameDuration: frame
        )
        media.moments = moments
        media.ahead = ahead
        var timelineClip = TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 10, timescale: 1))
        timelineClip.effects = effects
        let stack = ClipStack(clip: timelineClip, center: CGPoint(x: 8, y: 4), shift: .zero, frameDuration: frame)
        return DrawClip(content: .media(media), stack: stack, range: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1)), owner: UUID())
    }

    private func copy(_ track: CMPersistentTrackID, delay: CMTime) -> TrackCopy {
        TrackCopy(trackID: track, range: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1)), strength: 1, delay: delay)
    }

    private func harness() throws -> CompositorHarness {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0.2, 0.2, 0.2, 1))
        try harness.addSolid(track: 2, SIMD4(0.5, 0, 0, 1))
        return harness
    }

    @Test func feedbackScreensAnEarlierCopyOverThePicture() throws {
        let h = try harness()
        let effect = look(.feedback, ["copies": [1], "copyScale": [100], "copyRotation": [0], "hueStep": [0], "copyDecay": [0]])
        let drawn = try h.draw([clip([effect], moments: [copy(2, delay: frame)])], at: CMTime(value: 1, timescale: 1))
        // Screen: 1 − (1 − 0.2)(1 − 0.5) in red; green and blue as they were.
        #expect(close(h.pixel(drawn, x: 8, y: 4), SIMD4(0.6, 0.2, 0.2, 1), tolerance: 0.02))
        // With no earlier footage, nothing is added.
        let alone = try h.draw([clip([effect])], at: CMTime(value: 1, timescale: 1))
        #expect(close(h.pixel(alone, x: 8, y: 4), SIMD4(0.2, 0.2, 0.2, 1)))
    }

    @Test func feedbacksCopiesFadeByTheirDecay() throws {
        let h = try harness()
        let effect = look(.feedback, ["copies": [1], "copyScale": [100], "copyRotation": [0], "hueStep": [0], "copyDecay": [50]])
        let drawn = try h.draw([clip([effect], moments: [copy(2, delay: frame)])], at: CMTime(value: 1, timescale: 1))
        // Half the copy: 1 − 0.8 · (1 − 0.25).
        #expect(abs(h.pixel(drawn, x: 8, y: 4).x - 0.4) < 0.02)
    }

    @Test func feedbacksCopiesTurnInHue() throws {
        let h = try harness()
        func drawn(hueStep: Double) throws -> SIMD4<Float> {
            let effect = look(.feedback, ["copies": [1], "copyScale": [100], "copyRotation": [0], "hueStep": [hueStep], "copyDecay": [0]])
            return h.pixel(try h.draw([clip([effect], moments: [copy(2, delay: frame)])], at: CMTime(value: 1, timescale: 1)), x: 8, y: 4)
        }
        // The red copy turned a third of the way round is green, screened
        // over the gray: red as the picture's, green brighter.
        let still = try drawn(hueStep: 0), turned = try drawn(hueStep: 120)
        #expect(turned.y > still.y + 0.1)
        #expect(turned.x < still.x - 0.1)
    }

    @Test func slitScanTakesEachBandFromItsMoment() throws {
        let h = try harness()
        // Two bands a frame apart: the top now, the bottom a frame ago.
        let effect = look(.slitScan, ["bands": [2], "timeSpread": [1.0 / 24]])
        let drawn = try h.draw([clip([effect], moments: [copy(2, delay: frame)])], at: CMTime(value: 1, timescale: 1))
        // The harness's rows run from the frame's bottom up (it reverses
        // Core Image's, which already run from the top), so row 6 is near
        // the top of the frame.
        #expect(close(h.pixel(drawn, x: 8, y: 6), SIMD4(0.2, 0.2, 0.2, 1)))
        #expect(close(h.pixel(drawn, x: 8, y: 1), SIMD4(0.5, 0, 0, 1)))
    }

    @Test func slitScanRingsGoOutFromTheMiddle() throws {
        let h = try harness()
        let effect = look(.slitScan, ["bands": [2], "timeSpread": [1.0 / 24]], choices: ["slitDirection": "rings"])
        let drawn = try h.draw([clip([effect], moments: [copy(2, delay: frame)])], at: CMTime(value: 1, timescale: 1))
        #expect(close(h.pixel(drawn, x: 8, y: 4), SIMD4(0.2, 0.2, 0.2, 1)))
        #expect(close(h.pixel(drawn, x: 0, y: 0), SIMD4(0.5, 0, 0, 1)))
    }

    @Test func flowSmearOnAStillPictureLeavesItAlone() throws {
        var h = try harness()
        try h.addSolid(track: 3, SIMD4(0.2, 0.2, 0.2, 1))
        let drawn = try h.draw([clip([look(.flowSmear)], ahead: copy(3, delay: .zero))], at: CMTime(value: 1, timescale: 1))
        #expect(close(h.pixel(drawn, x: 8, y: 4), SIMD4(0.2, 0.2, 0.2, 1)))
    }

    @Test func theCompositionIsAskedForEachMomentOnce() {
        let feedback = look(.feedback, ["copies": [3], "feedbackDelay": [2]])
        #expect(feedback.momentDelays(frame: frame) == [2, 4, 6].map { CMTimeMultiply(frame, multiplier: $0) })
        // Three bands over a second at 24 fps: half a second and a second.
        let slit = look(.slitScan, ["bands": [3], "timeSpread": [1]])
        #expect(slit.momentDelays(frame: frame) == [12, 24].map { CMTimeMultiply(frame, multiplier: $0) })
        #expect(look(.flowSmear, ["framesAhead": [2]]).framesAhead == 2)
        #expect(feedback.changesOnItsOwn)
    }
}
