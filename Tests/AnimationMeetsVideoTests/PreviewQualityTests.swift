import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct PreviewGovernorTests {
    private func sample(_ time: Double, fps: Double, render: Double = 0.002) -> PreviewGovernor.Sample {
        PreviewGovernor.Sample(time: time, framesPerSecond: fps, renderSeconds: render)
    }

    @Test func fallingBehindTwiceStepsDownOneLevel() {
        var governor = PreviewGovernor()
        governor.startPlaying(at: 0)

        let changed1 = governor.record(sample(1, fps: 15), frameRate: 24)
        #expect(!changed1)
        let changed2 = governor.record(sample(1.5, fps: 15), frameRate: 24)
        #expect(changed2)
        #expect(governor.level == .half)
    }

    @Test func oneHiccupDoesNotCount() {
        var governor = PreviewGovernor()
        governor.startPlaying(at: 0)

        _ = governor.record(sample(1, fps: 15), frameRate: 24)
        _ = governor.record(sample(1.5, fps: 24), frameRate: 24)
        _ = governor.record(sample(2, fps: 15), frameRate: 24)
        #expect(governor.level == .full)
    }

    @Test func theBurstAfterStartingIsIgnored() {
        var governor = PreviewGovernor()
        governor.startPlaying(at: 0)

        _ = governor.record(sample(0.25, fps: 5), frameRate: 24)
        _ = governor.record(sample(0.5, fps: 5), frameRate: 24)
        #expect(governor.level == .full)
    }

    @Test func neverGoesBelowQuarter() {
        var governor = PreviewGovernor()
        governor.startPlaying(at: 0)
        var time = 1.0
        for _ in 0..<20 {
            _ = governor.record(sample(time, fps: 5, render: 0.2), frameRate: 24)
            time += 0.5
        }
        #expect(governor.level == .quarter)
    }

    @Test func pausingKeepsTheSettledLevelSoPlayingDoesNotSwapIt() {
        var governor = PreviewGovernor()
        governor.startPlaying(at: 0)
        _ = governor.record(sample(1, fps: 10), frameRate: 24)
        _ = governor.record(sample(1.5, fps: 10), frameRate: 24)

        governor.stopPlaying()
        #expect(governor.level == .half)
        governor.startPlaying(at: 10)
        #expect(governor.level == .half)
    }

    @Test func stepsUpOnlyAfterKeepingUpWithRoomToSpare() {
        var governor = PreviewGovernor()
        governor.startPlaying(at: 0)
        _ = governor.record(sample(1, fps: 10), frameRate: 24)
        _ = governor.record(sample(1.5, fps: 10), frameRate: 24)
        #expect(governor.level == .half)

        // Keeping up, but drawing takes too long to afford four times the pixels.
        let changed3 = governor.record(sample(8, fps: 24, render: 0.01), frameRate: 24)
        #expect(!changed3)
        // Too soon after stepping down.
        let changed4 = governor.record(sample(3, fps: 24, render: 0.001), frameRate: 24)
        #expect(!changed4)
        let changed5 = governor.record(sample(8.5, fps: 24, render: 0.001), frameRate: 24)
        #expect(changed5)
        #expect(governor.level == .full)
    }

    @Test func samplesWhilePausedAreIgnored() {
        var governor = PreviewGovernor()
        let changed6 = governor.record(sample(5, fps: 1), frameRate: 24)
        #expect(!changed6)
        let changed7 = governor.record(sample(6, fps: 1), frameRate: 24)
        #expect(!changed7)
        #expect(governor.level == .full)
    }
}

@Suite struct PreviewCompositionTests {
    @Test func thePreviewIsDrawnByTheLayeredCompositorAtAReducedSize() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "amv-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "gray.mov")
        try await writeMovie(to: url, segments: [(luma: 160, frames: 48)])

        var project = EditingProject.empty
        project.importClip(
            MediaClip(name: "gray", kind: .video, url: url, duration: CMTime(value: 48, timescale: 24),
                      frameRate: 24, colorSpace: .rec709, codecName: "H.264"),
            intoTimeline: project.rootTimelineID
        )
        let meter = RenderMeter()
        let composed = try await CompositionExporter.buildComposedTimeline(
            for: project, timelineID: project.rootTimelineID, forPreview: true, meter: meter
        )
        #expect(composed.videoComposition?.customVideoCompositorClass == SDRLayeredCompositor.self)
        let exported = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        #expect(exported.videoComposition?.customVideoCompositorClass == nil)

        let quarter = try #require(composed.videoComposition(scaledBy: PreviewLevel.quarter.scale))
        #expect(quarter.renderSize == CGSize(width: 480, height: 270))
        #expect(composed.videoComposition?.renderSize == CGSize(width: 1920, height: 1080))

        let generator = AVAssetImageGenerator(asset: composed.composition)
        generator.videoComposition = quarter
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: 12, timescale: 24)).image
        #expect(image.width == 480 && image.height == 270)

        var pixels = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixels, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -240, y: -135, width: 480, height: 270))
        #expect(abs(Int(pixels[1]) - 160) < 15)
        #expect(meter.drain().frames > 0)

        // HDR keeps half floats in the viewer.
        project.timelines[0].colorSpace = .rec2020PQ
        let hdr = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID, forPreview: true)
        #expect(hdr.videoComposition?.customVideoCompositorClass == LayeredCompositor.self)
    }
}
