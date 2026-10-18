import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ScrubAudioTests {
    @Test func aGrainIsTheMixUnderThePlayheadFadedAtItsEnds() async throws {
        let url = try AudioMixSupport.tone(amplitude: 0.25, seconds: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, _, layerID) = try AudioMixSupport.project(playing: url, seconds: 6)
        project.editVolume(of: layerID, in: project.rootTimelineID) { $0.set(-6, at: .zero) }
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        let scrub = ScrubAudio()
        scrub.setComposition(composed, curves: MixCurves(MixCurves.of(project)))

        let level = 0.25 * AudioLevel.gain(decibels: -6)
        for seconds in [0.5, 4.5] {
            let grain = try #require(await scrub.samples(at: seconds))
            #expect(grain.left.count == Int(ScrubAudio.grain * ScrubAudio.sampleRate))
            #expect(abs(grain.left[0]) < 0.001)
            #expect(abs(grain.left[grain.left.count / 2] - level) < 0.005)
            #expect(abs(grain.right[grain.right.count / 2] - level) < 0.005)
        }
        // Past the end there's nothing to hear.
        #expect(await scrub.samples(at: 20) == nil)
    }

    /// A grain fading out and the next fading in add up to a steady level
    /// across their overlap, with no dip or bump.
    @Test func crossfadesHoldTheLevel() {
        for step in 0...20 {
            let x = Float(step) / 20
            #expect(abs(ScrubAudio.fadeIn(x) + ScrubAudio.fadeIn(1 - x) - 1) < 0.0001)
        }
        #expect(ScrubAudio.fadeIn(0) == 0 && ScrubAudio.fadeIn(1) == 1)
        // They overlap by exactly the fade.
        #expect(abs(ScrubAudio.grain - ScrubAudio.hop - ScrubAudio.fade) < 1e-9)
    }

    @Test func grainsArePacedAndNeverCutOff() throws {
        var pacer = GrainPacer(hop: 0.07, lead: 0.015)
        // Nothing playing: the first move plays at once.
        #expect(pacer.request(1.0, now: 10) == .play(1.0))
        // Moves during it wait for the next start; only the newest plays.
        #expect(pacer.request(1.1, now: 10.01) == .wait(until: 10.055))
        #expect(pacer.request(1.2, now: 10.02) == .none)
        let fired = pacer.fire(now: 10.055)
        let next = try #require(fired)
        #expect(next.seconds == 1.2)
        // Exactly a hop after the first, so the two overlap by the fade.
        #expect(abs(next.start - 10.07) < 1e-9)
        // A wait with nothing new to play plays nothing.
        #expect(pacer.request(1.3, now: 10.08) == .wait(until: 10.125))
        pacer.reset()
        let afterReset = pacer.fire(now: 10.125)
        #expect(afterReset == nil)
        // After a pause the next move plays at once again.
        #expect(pacer.request(2.0, now: 11) == .play(2.0))
    }

    /// A drag crosses many pixels in each frame; the frame is heard once.
    @Test func aFrameIsHeardOnce() throws {
        var pacer = GrainPacer(hop: 0.07, lead: 0.015)
        #expect(pacer.request(1.0, now: 10) == .play(1.0))
        // Still on the frame playing, long after it started: nothing.
        #expect(pacer.request(1.0, now: 10.01) == .none)
        #expect(pacer.request(1.0, now: 10.5) == .none)
        // The next frame plays, at once since the grain is over.
        #expect(pacer.request(1.04, now: 10.6) == .play(1.04))
        // Waiting to play a frame, more moves within it change nothing.
        #expect(pacer.request(1.08, now: 10.61) == .wait(until: 10.655))
        #expect(pacer.request(1.08, now: 10.62) == .none)
        // Back to the frame just played, before the next starts: that is
        // the newest place, so it plays instead.
        #expect(pacer.request(1.04, now: 10.63) == .none)
        let fired = pacer.fire(now: 10.655)
        #expect(fired?.seconds == 1.04)
        // Playing from scratch again after a reset.
        pacer.reset()
        #expect(pacer.request(1.04, now: 12) == .play(1.04))
    }

    @Test func withoutSoundThereIsNoGrain() async {
        let scrub = ScrubAudio()
        #expect(await scrub.samples(at: 1) == nil)
    }
}
