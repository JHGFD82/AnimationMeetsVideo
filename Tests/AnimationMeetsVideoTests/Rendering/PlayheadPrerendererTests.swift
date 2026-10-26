import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Drawing the paused playhead's neighborhood ahead of playback
/// (`PlayheadPrerenderer`) into the viewer's `ClipPictureCache`.
@MainActor @Suite struct PlayheadPrerendererTests {
    @Test func itDrawsAheadOfThePlayheadFirstThenBehindWithinTheTimeline() {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 24)
        videoComposition.instructions = [LayeredInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), clips: [],
            renderSize: CGSize(width: 16, height: 8), colorSpace: .rec709
        )]
        let frames = PlayheadPrerenderer.frames(around: CMTime(value: 1, timescale: 2), of: videoComposition, ahead: 0.25, behind: 0.125)
        #expect(frames?.map(\.value) == [12, 13, 14, 15, 16, 17, 18, 11, 10, 9])
        // Not past the end, nor before the start.
        let atEnd = PlayheadPrerenderer.frames(around: CMTime(value: 22, timescale: 24), of: videoComposition, ahead: 1, behind: 0)
        #expect(atEnd?.map(\.value) == [22, 23])
        let atStart = PlayheadPrerenderer.frames(around: .zero, of: videoComposition, ahead: 0, behind: 1)
        #expect(atStart?.map(\.value) == [0])
    }

    @Test func playingTakesThePicturesDrawnAhead() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let placed = try await fixture.addClip(luma: 120, frames: 24)
        var exposure = Effect(kind: .color, controls: [EffectControl(kind: .exposure)])
        exposure.controls[0].number = AnimatedValue(ComponentValue(values: [1]))
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.effects = [exposure] }
        let options = DrawingOptions(liveValues: LiveValues())
        let composed = try await CompositionExporter.buildComposedTimeline(
            for: fixture.project, timelineID: fixture.timelineID, forPreview: true, meter: RenderMeter(), options: options
        )
        let videoComposition = try #require(composed.videoComposition)

        let prerenderer = PlayheadPrerenderer()
        prerenderer.settleSeconds = 0
        prerenderer.aheadSeconds = 0.25
        prerenderer.behindSeconds = 0
        prerenderer.start(composition: composed.composition, videoComposition: videoComposition, around: .zero)
        await prerenderer.finish()
        #expect(prerenderer.drawnTimes.count == 7)
        #expect(options.pictures.counts.kept == 7)

        // The player's own frames there, drawn as it plays, take them.
        options.update(isPlaying: true)
        let generator = AVAssetImageGenerator(asset: composed.composition)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        _ = try await generator.image(at: CMTime(value: 3, timescale: 24))
        #expect(options.pictures.counts.hits == 1)

        // Paused frames are drawn at paused quality, so they don't.
        options.update(isPlaying: false)
        _ = try await generator.image(at: CMTime(value: 4, timescale: 24))
        #expect(options.pictures.counts.hits == 1)
    }

    @Test func plainStretchesArentDrawnAhead() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        try await fixture.addClip(luma: 120, frames: 24)
        let options = DrawingOptions(liveValues: LiveValues())
        let composed = try await CompositionExporter.buildComposedTimeline(
            for: fixture.project, timelineID: fixture.timelineID, forPreview: true, options: options
        )
        let prerenderer = PlayheadPrerenderer()
        prerenderer.settleSeconds = 0
        prerenderer.start(composition: composed.composition, videoComposition: try #require(composed.videoComposition), around: .zero)
        await prerenderer.finish()
        #expect(prerenderer.drawnTimes.isEmpty)
        #expect(options.pictures.counts.kept == 0)
    }
}
