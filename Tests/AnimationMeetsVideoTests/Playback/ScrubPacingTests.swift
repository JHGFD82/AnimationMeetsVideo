import Foundation
import Testing
@testable import AnimationMeetsVideo

/// When the paused seek queue seeks roughly, and how roughly (see
/// docs/rendering.md, "Rough, then exact").
@Suite struct ScrubPacingTests {
    /// Moves `step` seconds of the timeline apart, `every` seconds apart,
    /// from 0 at time 0: the tolerance of each.
    private func moves(_ count: Int, step: Double, every: Double, pacing: inout ScrubPacing, from start: Double = 0) -> [Double] {
        (0..<count).map { pacing.tolerance(forMoveTo: Double($0) * step, at: start + Double($0) * every) }
    }

    @Test func aMoveOnItsOwnIsExact() {
        var pacing = ScrubPacing()
        #expect(pacing.tolerance(forMoveTo: 30, at: 5) == 0)
        // Another a while later, however far: a click in the ruler.
        #expect(pacing.tolerance(forMoveTo: 2, at: 5.5) == 0)
    }

    @Test func movesAtAboutNormalSpeedStayExact() {
        var pacing = ScrubPacing()
        // An arrow key held: a frame each frame.
        #expect(moves(48, step: 1.0 / 24, every: 1.0 / 24, pacing: &pacing).allSatisfy { $0 == 0 })
        // A slow drag to find a frame, a frame each screen refresh.
        pacing.reset()
        #expect(moves(60, step: 1.0 / 60, every: 1.0 / 60, pacing: &pacing).allSatisfy { $0 == 0 })
    }

    @Test func fastMovesSeekWithinWhatTheyCoverInALead() {
        var pacing = ScrubPacing()
        // A tenth of a second of the timeline every 16 ms: 6.25 times normal.
        let tolerances = moves(30, step: 0.1, every: 0.016, pacing: &pacing)
        #expect(tolerances[0] == 0)
        #expect(tolerances.dropFirst().allSatisfy { abs($0 - 6.25 * ScrubPacing.lead) < 1e-9 })
    }

    @Test func backAndForthCountsBothWays() {
        var pacing = ScrubPacing()
        // Half a second there and back in 50 ms: 20 times normal.
        _ = pacing.tolerance(forMoveTo: 1, at: 0)
        _ = pacing.tolerance(forMoveTo: 1.5, at: 0.025)
        #expect(abs(pacing.tolerance(forMoveTo: 1, at: 0.05) - 2) < 1e-9)
    }

    @Test func aRestStartsAfresh() {
        var pacing = ScrubPacing()
        #expect(moves(10, step: 0.5, every: 0.016, pacing: &pacing).last ?? 0 > 0)
        #expect(pacing.tolerance(forMoveTo: 10, at: 0.016 * 9 + ScrubPacing.restSeconds + 0.05) == 0)
    }

    @Test func noFartherOffThanTheMost() {
        var pacing = ScrubPacing()
        // A minute of the timeline in one refresh.
        _ = pacing.tolerance(forMoveTo: 0, at: 0)
        #expect(pacing.tolerance(forMoveTo: 60, at: 0.016) == ScrubPacing.farthest)
    }
}
