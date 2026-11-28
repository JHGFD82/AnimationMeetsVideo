import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A clip's volume counts in its source time; on a clip whose speed
/// changes, it must be heard where the source moment it was keyed on plays
/// (code-review-notes.md, F30). It was read at the speed the clip starts
/// at, so on a ramp every keyframe was heard late, in playback and export.
@Suite struct RetimedMixTests {
    /// Four seconds of a tone on a clip ramping from 50% at its start to
    /// 200% at its end, silent until 2 s into its source and full after.
    private func ramped() throws -> (EditingProject, clip: TimelineClip) {
        let url = try AudioMixSupport.tone(frequency: 440, amplitude: 0.25, seconds: 4)
        var (project, clipID, _) = try AudioMixSupport.project(playing: url, seconds: 4)
        let t = project.rootTimelineID
        project.editClip(clipID, in: t) { clip in
            clip.time.speed.setAnimated(true, at: .zero)
            clip.time.speed.set(50, at: .zero)
            clip.time.speed.set(200, at: CMTime(value: 4, timescale: 1))
            clip.volume.setAnimated(true, at: .zero)
            clip.volume.set(AudioLevel.silence, at: .zero)
            clip.volume.toggleHold(at: .zero)
            clip.volume.set(0, at: CMTime(value: 2, timescale: 1))
        }
        let clip = try #require(project.clipAndLayer(clipID, in: t)?.clip)
        #expect(clip.trimEnd == CMTime(value: 4, timescale: 1) && clip.time.speed.isAnimated)
        return (project, clip)
    }

    @Test func aVolumeStepOnARampIsHeardWhereItsSourceMomentPlays() async throws {
        let (project, clip) = try ramped()
        // ∫ 100 / (50 + 37.5 s) ds from 0 to 2: about 2.44 s, where at the
        // starting 50% it would be 4 s, past the clip's end at about 3.70 s.
        let step = clip.timelineTime(forSourceTime: CMTime(value: 2, timescale: 1)).seconds
        #expect(abs(step - 100 / 37.5 * log(2.5)) < 0.01)
        let end = clip.endOffset.seconds

        let before = try await AudioMixSupport.loudest(of: project, after: 0.2, before: step - 0.15)
        let after = try await AudioMixSupport.loudest(of: project, after: step + 0.15, before: end - 0.15)
        #expect(before.x < 0.02, "the step was heard early: \(before.x)")
        #expect(after.x > 0.15, "the step was heard late or not at all: \(after.x)")
    }

    @Test func theMapFollowsTheClipsOwnTimeMapAtItsPieces() throws {
        let (_, clip) = try ramped()
        let window = CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1))
        let offset = CMTime(value: 3, timescale: 1)
        let map = try #require(CompositionExporter.mixTimeMap(
            of: clip, window: window, offset: offset, frameDuration: CMTime(value: 1, timescale: 24)
        ))
        // Exact where the sound's pieces meet; between, each piece is a
        // straight line, as the sound is placed: a chord of a sixth of a
        // second, off the curve by at most h²/8 times its bend, 0.75 s/s²
        // at this ramp's steep end, so 2.6 ms.
        let edges = CompositionExporter.retimedEdges(
            of: clip, over: CMTimeRange(start: clip.startOffset, end: clip.endOffset), frameDuration: CMTime(value: 1, timescale: 24)
        )
        #expect(edges.count > 20)
        for edge in edges {
            #expect(abs(map.local(seconds: CMTimeAdd(edge, offset).seconds) - clip.sourceTime(atTimelineTime: edge).seconds) < 1e-9)
        }
        for seconds in stride(from: 0.0, through: clip.endOffset.seconds, by: 0.05) {
            let expected = clip.sourceTime(atTimelineTime: CMTime(seconds: seconds, preferredTimescale: 240_000)).seconds
            #expect(abs(map.local(seconds: seconds + 3) - expected) < 0.003)
        }
        // A steady speed needs no map: one rate describes it.
        var steady = clip
        steady.time.speed = AnimatedValue(50.0)
        #expect(CompositionExporter.mixTimeMap(of: steady, window: window, offset: offset, frameDuration: CMTime(value: 1, timescale: 24)) == nil)
    }
}
