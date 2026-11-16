import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// One loop region per timeline across the project's players
/// (docs/loop-region.md, "In every window"): a change made through one is
/// made in the others on that timeline, as if made there.
@MainActor
@Suite struct LoopRegionsTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }
    private let frame = CMTime(value: 1, timescale: 24)
    private let main = UUID(), other = UUID()

    /// A player's loop in `shared`, showing `timelineID`, which records its
    /// jumps and stands in a clock at `now`.
    @MainActor
    private final class Player {
        let loop = PlaybackLoop(player: AVPlayer())
        var now = CMTime.zero
        var jumps: [CMTime] = []

        init(_ shared: LoopRegions, showing timelineID: UUID, saved: LoopRegion? = nil) {
            loop.shared = shared
            loop.show(saved, duration: CMTime(value: 60, timescale: 1), frameDuration: CMTime(value: 1, timescale: 24), timelineID: timelineID)
            loop.playerTime = { [unowned self] in self.now }
            loop.jump = { [unowned self] in self.jumps.append($0) }
        }
    }

    @Test func aRegionDrawnInOneWindowIsInTheOthers() {
        let shared = LoopRegions()
        let a = Player(shared, showing: main)
        let b = Player(shared, showing: main)
        let elsewhere = Player(shared, showing: other)

        a.loop.draw(LoopRegion(start: seconds(4), end: seconds(8)))
        #expect(b.loop.region == LoopRegion(start: seconds(4), end: seconds(8)))
        #expect(elsewhere.loop.region == nil)

        b.loop.adjust(to: LoopRegion(start: seconds(5), end: seconds(8)))
        #expect(a.loop.region?.start == seconds(5))
        b.loop.toggle()
        #expect(a.loop.region?.isOn == false)
        a.loop.remove()
        #expect(b.loop.region == nil)
    }

    @Test func aPlayingWindowTurnsBackAsItsOwnChangeWould() {
        let shared = LoopRegions()
        let a = Player(shared, showing: main)
        let b = Player(shared, showing: main)
        b.loop.playingChanged(true)
        b.now = seconds(30)

        a.loop.draw(LoopRegion(start: seconds(4), end: seconds(8)))
        #expect(b.jumps == [seconds(4)])
        #expect(a.jumps.isEmpty)
        #expect(b.loop.watchedRange == CMTimeRange(start: seconds(4), end: seconds(8)))

        // Moved around where it plays: no jump there.
        b.now = seconds(6)
        a.loop.adjust(to: LoopRegion(start: seconds(5), end: seconds(9)))
        #expect(b.jumps == [seconds(4)])
    }

    @Test func aWindowOpenedLaterShowsTheSharedRegionNotItsOwn() {
        let shared = LoopRegions()
        let a = Player(shared, showing: main, saved: LoopRegion(start: seconds(1), end: seconds(3)))
        a.loop.adjust(to: LoopRegion(start: seconds(2), end: seconds(6)))
        // What this window last saved is older than what the others have.
        let b = Player(shared, showing: main, saved: LoopRegion(start: seconds(1), end: seconds(3)))
        #expect(b.loop.region == LoopRegion(start: seconds(2), end: seconds(6)))
        // A timeline no player has shown takes what was saved for it.
        let c = Player(shared, showing: other, saved: LoopRegion(start: seconds(7), end: seconds(9)))
        #expect(c.loop.region?.start == seconds(7))
    }

    /// Two views keeping "on only while its bar shows" both ask, from
    /// different players: it ends off, not toggled back on.
    @Test func setOnFromTwoWindowsIsOnce() {
        let shared = LoopRegions()
        let a = Player(shared, showing: main)
        let b = Player(shared, showing: main)
        a.loop.draw(LoopRegion(start: seconds(4), end: seconds(8)))
        a.loop.setOn(false)
        b.loop.setOn(false)
        #expect(a.loop.region?.isOn == false && b.loop.region?.isOn == false)
    }

    @Test func aPlayerGoneIsLetGo() {
        let shared = LoopRegions()
        let a = Player(shared, showing: main)
        do {
            let b = Player(shared, showing: main)
            _ = b
        }
        a.loop.draw(LoopRegion(start: seconds(4), end: seconds(8)))
        #expect(shared.region(of: main) == LoopRegion(start: seconds(4), end: seconds(8)))
    }
}
