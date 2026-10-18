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

    @Test func withoutSoundThereIsNoGrain() async {
        let scrub = ScrubAudio()
        #expect(await scrub.samples(at: 1) == nil)
    }
}
