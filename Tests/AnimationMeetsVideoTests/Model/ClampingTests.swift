import Testing
@testable import AnimationMeetsVideo

@Suite struct ClampingTests {
    @Test func aValueOutsideTheBoundsTakesTheNearerOne() {
        #expect(1.5.clamped(between: 0, and: 1) == 1)
        #expect((-2).clamped(between: 0, and: 1) == 0)
        #expect(0.25.clamped(between: 0, and: 1) == 0.25)
    }

    @Test func crossedBoundsGiveTheHighOneAsMinOfMaxDoesWithoutTrapping() {
        #expect(5.clamped(between: 3, and: 1) == 1)
        #expect(5.clamped(between: 3, and: 1) == min(max(5, 3), 1))
        // A curve with too few points for a segment clamps to -1, not a trap.
        #expect(0.clamped(between: 0, and: -1) == -1)
    }
}
