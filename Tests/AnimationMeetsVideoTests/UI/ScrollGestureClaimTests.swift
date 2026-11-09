import AppKit
import Testing
@testable import AnimationMeetsVideo

/// A scroll is a view's or not as a whole, by where it began.
@Suite struct ScrollGestureClaimTests {
    /// Sends `events` (phase, momentum phase, whether the view would take
    /// it) and returns whether each was used up, and how many the view was
    /// offered.
    private func run(_ events: [(NSEvent.Phase, NSEvent.Phase, Bool)], wheelTimes: [TimeInterval]? = nil) -> ([Bool], Int) {
        var claim = ScrollGestureClaim()
        var offered = 0
        var used: [Bool] = []
        for (index, event) in events.enumerated() {
            used.append(claim.handle(phase: event.0, momentumPhase: event.1, moves: true, time: wheelTimes?[index] ?? 0) {
                offered += 1
                return event.2
            })
        }
        return (used, offered)
    }

    @Test func aTrackpadScrollThatBeganElsewhereStaysThePanels() {
        // The dot comes under the pointer halfway through.
        let (used, offered) = run([([.began], [], false), ([.changed], [], true), ([.changed], [], true), ([.ended], [], true)])
        #expect(used == [false, false, false, false])
        #expect(offered == 1)
    }

    @Test func aTrackpadScrollThatBeganOverTheDotIsTheViewsAndSwallowsItsMomentum() {
        let (used, offered) = run([
            ([.began], [], true), ([.changed], [], false), ([.ended], [], false),
            ([], [.began], true), ([], [.changed], true), ([], [.ended], true),
        ])
        #expect(used == [true, true, true, true, true, true])
        // Momentum is never offered.
        #expect(offered == 3)
    }

    @Test func momentumAfterAScrollThePanelHadIsNeverTheViews() {
        let (used, offered) = run([([.began], [], false), ([.ended], [], false), ([], [.began], true), ([], [.changed], true)])
        #expect(used == [false, false, false, false])
        #expect(offered == 1)
    }

    @Test func aScrollThatOnlyTouchedDecidesWhenItFirstMoves() {
        var claim = ScrollGestureClaim()
        #expect(!claim.handle(phase: .mayBegin, momentumPhase: [], moves: false, time: 0) { true })
        #expect(claim.handle(phase: .began, momentumPhase: [], moves: true, time: 0) { true })
    }

    @Test func aMouseWheelsRunOfClicksIsOneScrollAndAPauseStartsAnother() {
        let (used, _) = run(
            [([], [], false), ([], [], true), ([], [], true), ([], [], true)],
            wheelTimes: [0, 0.1, 0.2, 1]
        )
        #expect(used == [false, false, false, true])
    }
}
