import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The viewer's paused frame drawn again with new values from what the
/// player's compositor drew it from (`SourceCapture`, `FrameRedrawer`), as
/// a value edit does.
@MainActor @Suite struct LiveRedrawTests {
    /// The encoded green level (0...255) at a point of a frame, as fractions
    /// from the top left: the bytes as drawn, without any color conversion.
    private func level(_ buffer: CVPixelBuffer, x: Double, y: Double) throws -> Int {
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let px = min(width - 1, Int(Double(width) * x)), py = min(height - 1, Int(Double(height) * y))
        return Int(base[py * CVPixelBufferGetBytesPerRow(buffer) + px * 4 + 1])
    }

    /// The same for an image the compositor drew.
    private func level(_ image: CGImage, x: Double, y: Double) throws -> Int {
        let data = try #require(image.dataProvider?.data as Data?)
        let px = min(image.width - 1, Int(Double(image.width) * x)), py = min(image.height - 1, Int(Double(image.height) * y))
        #expect(image.bitsPerPixel == 32)
        let alphaFirst = [CGImageAlphaInfo.first, .premultipliedFirst, .noneSkipFirst].contains(image.alphaInfo)
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        // Green is second from the alpha end in ARGB and RGBA alike.
        let green = alphaFirst == little ? 1 : 2
        return Int(data[py * image.bytesPerRow + px * 4 + green])
    }

    /// The frame at `time` as the compositor draws it, which keeps it in
    /// `capture` when that is armed for it.
    @discardableResult
    private func draw(_ composed: ComposedTimeline, at time: CMTime, capture: SourceCapture? = nil) async throws -> CGImage {
        let composed = capture.map { composed.capturing(into: $0) } ?? composed
        let generator = AVAssetImageGenerator(asset: composed.composition)
        generator.videoComposition = composed.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: time).image
    }

    /// The next frame the redrawer draws for `request`.
    private func redraw(_ redrawer: FrameRedrawer, _ request: FrameRedrawer.Request) async throws -> CVPixelBuffer {
        let frame: HandedOver<CVPixelBuffer>? = await withCheckedContinuation { continuation in
            var resumed = false
            redrawer.onFrame = { buffer, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: HandedOver(value: buffer))
            }
            if !redrawer.redraw(request) {
                resumed = true
                continuation.resume(returning: nil)
            }
        }
        return try #require(frame).value
    }

    /// Footage under a shape layer of a gray box, the shape's fill `gray`.
    private func fixture() async throws -> (DrawingFixture, shape: UUID) {
        var fixture = try DrawingFixture()
        _ = try await fixture.addClip(luma: 40, frames: 48)
        let shape = try fixture.addShape()
        fixture.setControl(.fill, [0.8, 0.8, 0.8, 1], ofClip: shape.clipID)
        return (fixture, shape.clipID)
    }

    @Test func aValueEditIsDrawnFromTheCapturedFrame() async throws {
        var (fixture, shape) = try await fixture()
        defer { fixture.cleanUp() }
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        let built = try await fixture.build(forPreview: true)
        let capture = SourceCapture()
        capture.arm(at: time)
        let first = try await draw(built, at: time, capture: capture)
        #expect(try level(first, x: 0.5, y: 0.5) > 180)
        let recorded = try #require(capture.recorded)
        #expect(recorded.pixelFormat == built.viewerPixelFormat)

        // Darker, drawn without a build.
        fixture.setControl(.fill, [0.2, 0.2, 0.2, 1], ofClip: shape)
        let redrawer = FrameRedrawer()
        let second = try await redraw(redrawer, .init(
            recorded: recorded, values: fixture.project.clipsByID, size: recorded.instruction.renderSize, token: 1
        ))
        let fast = try level(second, x: 0.5, y: 0.5)
        #expect(fast < 80)

        // The same as a build of the edit draws.
        let full = try await draw(try await fixture.build(forPreview: true), at: time)
        #expect(abs(try level(full, x: 0.5, y: 0.5) - fast) < 4)
        #expect(abs(try level(full, x: 0.1, y: 0.1) - level(second, x: 0.1, y: 0.1)) < 4)
    }

    /// A paused player draws the frames after the paused one ahead; only the
    /// one armed for is kept.
    @Test func onlyTheArmedFrameIsKept() async throws {
        let (fixture, _) = try await fixture()
        defer { fixture.cleanUp() }
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        let built = try await fixture.build(forPreview: true)
        let capture = SourceCapture()
        try await draw(built, at: time, capture: capture)
        #expect(capture.recorded == nil)

        capture.arm(at: time)
        try await draw(built, at: CMTime(seconds: 1.5, preferredTimescale: 600), capture: capture)
        #expect(capture.recorded == nil)
        try await draw(built, at: time, capture: capture)
        let recorded = try #require(capture.recorded)
        #expect(CMTimeCompare(recorded.time, time) <= 0)

        // Armed again for the same moment, it keeps it; for another, not.
        capture.arm(at: time)
        #expect(capture.recorded != nil)
        capture.arm(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        #expect(capture.recorded == nil)
    }

    /// A rendered stretch holds the values it was made with, so its frame
    /// can't be drawn again with others; drawn from its clips (the
    /// composition's own unrendered drawing), it can.
    @Test func aRenderedStretchIsDrawnFromItsClipsForValues() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.addClip(luma: 40)
        let top = try await fixture.addClip(luma: 220)
        fixture.setTransform([(.opacity, [50])], ofClip: top.clipID)
        let time = CMTime(seconds: 1, preferredTimescale: 600)

        let root = FileManager.default.temporaryDirectory.appending(path: "amv-redraw-\(UUID().uuidString).amv", directoryHint: .isDirectory)
        try ProjectStore.preparePackage(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RenderCache(packageURL: root)
        let plain = try await fixture.build(forPreview: true)
        let needing = plain.segments.filter(\.needsRender)
        try #require(!needing.isEmpty, "The stack should need a render")
        for segment in needing { try await SegmentRenderer.render(segment, from: plain, into: cache) }
        let withRenders = try await CompositionExporter.buildComposedTimeline(
            for: fixture.project, timelineID: fixture.timelineID, forPreview: true, cache: cache
        )
        let values = fixture.project.clipsByID

        let capture = SourceCapture()
        capture.arm(at: time)
        try await draw(withRenders, at: time, capture: capture)
        let rendered = try #require(capture.recorded)
        #expect(!FrameRedrawer.canDraw(rendered, values: values))
        #expect(FrameRedrawer.canDraw(rendered, values: nil))

        var unrendered = withRenders
        let composition = try #require(withRenders.unrenderedVideoComposition)
        unrendered.videoComposition = composition
        let again = SourceCapture()
        again.arm(at: time)
        try await draw(unrendered, at: time, capture: again)
        #expect(FrameRedrawer.canDraw(try #require(again.recorded), values: values))
    }

    /// The frames the player plays are drawn with a held drag's values
    /// (`LiveValues`), then as built once the drag's values are in the build.
    @Test func aPlayingFrameFollowsAHeldDrag() async throws {
        var (fixture, shape) = try await fixture()
        defer { fixture.cleanUp() }
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        // Its own, since the editor in other tests sets the app's.
        let live = LiveValues()
        let built = try await CompositionExporter.buildComposedTimeline(
            for: fixture.project, timelineID: fixture.timelineID, forPreview: true, options: DrawingOptions(liveValues: live)
        )
        #expect(try await grayLevel(of: built, at: time) > 180)

        fixture.setControl(.fill, [0.2, 0.2, 0.2, 1], ofClip: shape)
        live.clips = fixture.project.clipsByID
        #expect(try await grayLevel(of: built, at: time) < 80)

        live.clips = nil
        #expect(try await grayLevel(of: built, at: time) > 180)
    }
}
