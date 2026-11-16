import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

/// The loop's watch and its jumps (docs/loop-region.md, "Playback"),
/// driven through `playingChanged` and a stand-in clock, without sound.
@MainActor
@Suite struct PlaybackLoopTests {
    private let frame = CMTime(value: 1, timescale: 24)

    /// A loop on a 60 s timeline whose player is at `now`, recording each
    /// jump.
    @MainActor
    private final class Rig {
        let loop = PlaybackLoop(player: AVPlayer())
        var now = CMTime.zero
        var jumps: [CMTime] = []

        init(duration: CMTime = CMTime(value: 60, timescale: 1)) {
            loop.show(nil, duration: duration, frameDuration: CMTime(value: 1, timescale: 24))
            loop.playerTime = { [unowned self] in self.now }
            loop.jump = { [unowned self] time in self.jumps.append(time) }
        }
    }

    @Test func theActiveRangeIsTheRegionWhileOn() {
        let rig = Rig()
        #expect(rig.loop.activeRange == nil)
        rig.loop.draw(LoopRegion(start: seconds(4), end: seconds(8), isOn: false))
        // Drawn is on, whatever it was handed.
        #expect(rig.loop.region?.isOn == true)
        #expect(rig.loop.activeRange == CMTimeRange(start: seconds(4), end: seconds(8)))
        rig.loop.toggle()
        #expect(rig.loop.activeRange == nil)
        #expect(rig.loop.region != nil)
        rig.loop.toggle()
        rig.loop.isSuspended = true
        #expect(rig.loop.activeRange == nil)
        rig.loop.isSuspended = false
        #expect(rig.loop.activeRange != nil)
        rig.loop.remove()
        #expect(rig.loop.activeRange == nil && rig.loop.region == nil)
    }

    @Test func aWindowOrAShorterTimelineCutsTheRange() {
        let rig = Rig()
        rig.loop.draw(LoopRegion(start: seconds(4), end: seconds(8)))
        rig.loop.narrow(to: CMTimeRange(start: seconds(5), end: seconds(20)))
        #expect(rig.loop.activeRange == CMTimeRange(start: seconds(5), end: seconds(8)))
        rig.loop.narrow(to: nil)
        rig.loop.update(duration: seconds(6), frameDuration: frame)
        #expect(rig.loop.activeRange == CMTimeRange(start: seconds(4), end: seconds(6)))
        // Too little left to loop; the region itself stays.
        rig.loop.update(duration: seconds(4.2), frameDuration: frame)
        #expect(rig.loop.activeRange == nil)
        #expect(rig.loop.region?.end == seconds(8))
    }

    @Test func theEndIsWatchedOnlyWhilePlaying() {
        let rig = Rig()
        rig.loop.draw(LoopRegion(start: seconds(4), end: seconds(8)))
        #expect(rig.loop.watchedRange == nil)
        rig.loop.playingChanged(true)
        #expect(rig.loop.watchedRange == CMTimeRange(start: seconds(4), end: seconds(8)))
        rig.loop.toggle()
        #expect(rig.loop.watchedRange == nil)
        rig.loop.toggle()
        rig.loop.isSuspended = true
        #expect(rig.loop.watchedRange == nil)
        rig.loop.isSuspended = false
        rig.loop.playingChanged(false)
        #expect(rig.loop.watchedRange == nil)
    }

    @Test func aRangeToTheEndIsWatchedJustShortOfIt() {
        let rig = Rig(duration: seconds(10))
        rig.loop.draw(LoopRegion(start: seconds(6), end: seconds(10)))
        rig.loop.playingChanged(true)
        let watched = rig.loop.watchedRange
        #expect(watched?.start == seconds(6))
        #expect(watched?.end == CMTimeSubtract(seconds(10), PlaybackLoop.endMargin))
    }

    @Test func turningOnOrDrawingWhilePlayingJumpsToTheStart() {
        let rig = Rig()
        rig.now = seconds(30)
        rig.loop.draw(LoopRegion(start: seconds(4), end: seconds(8)))
        #expect(rig.jumps.isEmpty) // Paused: nothing moves.
        rig.loop.playingChanged(true)
        rig.loop.toggle()
        #expect(rig.jumps.isEmpty) // Off: plays on.
        rig.loop.toggle()
        #expect(rig.jumps == [seconds(4)])
        rig.now = seconds(5)
        rig.loop.draw(LoopRegion(start: seconds(10), end: seconds(12)))
        #expect(rig.jumps == [seconds(4), seconds(10)])
    }

    @Test func adjustingJumpsOnlyFromOutsideTheNewRange() {
        let rig = Rig()
        rig.loop.draw(LoopRegion(start: seconds(4), end: seconds(8)))
        rig.loop.playingChanged(true)
        rig.now = seconds(6)
        rig.loop.adjust(to: LoopRegion(start: seconds(5), end: seconds(9)))
        #expect(rig.jumps.isEmpty)
        rig.loop.adjust(to: LoopRegion(start: seconds(7), end: seconds(9)))
        #expect(rig.jumps == [seconds(7)])
        // The same range again (a color, say) never jumps.
        rig.now = seconds(1)
        rig.loop.adjust(to: LoopRegion(start: seconds(7), end: seconds(9)))
        #expect(rig.jumps == [seconds(7)])
        // At the end itself is outside.
        rig.now = seconds(12)
        rig.loop.adjust(to: LoopRegion(start: seconds(10), end: seconds(12)))
        #expect(rig.jumps == [seconds(7), seconds(10)])
    }

    /// What two views keeping "on only while its bar shows" both ask: the
    /// second asking does nothing, where two toggles would undo each other.
    @Test func setOnTwiceIsOnce() {
        let rig = Rig()
        rig.loop.setOn(true)
        #expect(rig.loop.region == nil)
        rig.loop.draw(LoopRegion(start: seconds(4), end: seconds(8)))
        rig.loop.setOn(false)
        rig.loop.setOn(false)
        #expect(rig.loop.region?.isOn == false)
        rig.loop.playingChanged(true)
        rig.loop.setOn(true)
        rig.loop.setOn(true)
        #expect(rig.loop.isOn)
        // Turned on while playing, it went to the start once.
        #expect(rig.jumps == [seconds(4)])
    }

    @Test func playStartsInsideFromThePlayheadElseFromTheStart() {
        let rig = Rig()
        #expect(rig.loop.playStart(from: seconds(1)) == nil)
        rig.loop.draw(LoopRegion(start: seconds(4), end: seconds(8)))
        #expect(rig.loop.playStart(from: seconds(1)) == seconds(4))
        #expect(rig.loop.playStart(from: seconds(4)) == seconds(4))
        #expect(rig.loop.playStart(from: seconds(6)) == seconds(6))
        // From a frame before the end on, and past it, from the start.
        #expect(rig.loop.playStart(from: CMTimeSubtract(seconds(8), frame)) == CMTimeSubtract(seconds(8), frame))
        #expect(rig.loop.playStart(from: seconds(7.99)) == seconds(4))
        #expect(rig.loop.playStart(from: seconds(20)) == seconds(4))
        rig.loop.toggle()
        #expect(rig.loop.playStart(from: seconds(1)) == nil)
    }

    @Test func showingAnotherTimelineDropsABackwardRegion() {
        let rig = Rig()
        rig.loop.show(LoopRegion(start: seconds(8), end: seconds(4)), duration: seconds(60), frameDuration: frame)
        #expect(rig.loop.region == nil)
        rig.loop.show(LoopRegion(start: seconds(4), end: seconds(8), isOn: false), duration: seconds(60), frameDuration: frame)
        #expect(rig.loop.region?.isOn == false)
        #expect(rig.jumps.isEmpty)
    }

    @Test func thePlayerStartsALoopFromItsStart() {
        let playback = PlaybackModel()
        playback.showTimeline(from: seconds(20))
        playback.loop.show(LoopRegion(start: seconds(4), end: seconds(8)), duration: seconds(60), frameDuration: frame)
        playback.togglePlayback()
        #expect(playback.currentTime == seconds(4))
        playback.player.pause()
    }
}
