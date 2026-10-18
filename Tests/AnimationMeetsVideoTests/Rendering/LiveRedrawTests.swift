import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The viewer's paused frame drawn again with new values from what the last
/// build decoded (`LiveFrameRenderer.redraw`), as dragging a value does.
@MainActor @Suite struct LiveRedrawTests {
    /// The encoded green level (0...255) at a point of `picture`, as
    /// fractions from the top left: the bytes as drawn, without any color
    /// conversion, so an image and a frame compare as the compositor drew
    /// them.
    private func level(_ picture: CoverPicture, x: Double, y: Double) throws -> Int {
        switch picture {
        case .image(let image):
            let data = try #require(image.dataProvider?.data as Data?)
            let px = min(image.width - 1, Int(Double(image.width) * x)), py = min(image.height - 1, Int(Double(image.height) * y))
            #expect(image.bitsPerPixel == 32)
            let alphaFirst = [CGImageAlphaInfo.first, .premultipliedFirst, .noneSkipFirst].contains(image.alphaInfo)
            let little = image.bitmapInfo.contains(.byteOrder32Little)
            // Green is second from the alpha end in ARGB and RGBA alike.
            let green = alphaFirst == little ? 1 : 2
            return Int(data[py * image.bytesPerRow + px * 4 + green])
        case .frame(let buffer):
            #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let px = min(width - 1, Int(Double(width) * x)), py = min(height - 1, Int(Double(height) * y))
            return Int(base[py * CVPixelBufferGetBytesPerRow(buffer) + px * 4 + 1])
        }
    }

    /// The next frame the renderer draws.
    private func nextFrame(_ renderer: LiveFrameRenderer, _ start: () -> Void) async throws -> CoverPicture {
        let frame: CoverPicture? = await withCheckedContinuation { continuation in
            var resumed = false
            renderer.onFrame = { image, _, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
            start()
        }
        return try #require(frame)
    }

    /// Footage under a shape layer of a gray box, the shape's fill `gray`.
    private func fixture() async throws -> (DrawingFixture, shape: UUID) {
        var fixture = try DrawingFixture()
        _ = try await fixture.addClip(luma: 40, frames: 48)
        let shape = try fixture.addShape()
        fixture.setControl(.fill, [0.8, 0.8, 0.8, 1], ofClip: shape.clipID)
        return (fixture, shape.clipID)
    }

    @Test func aValueEditIsDrawnFromTheLastBuild() async throws {
        var (fixture, shape) = try await fixture()
        defer { fixture.cleanUp() }
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        let renderer = LiveFrameRenderer()
        let built = try await fixture.build(forPreview: true)
        let first = try await nextFrame(renderer) {
            renderer.submit(.init(composed: built, scale: 1, time: time, structure: fixture.project.structure))
        }
        #expect(try level(first, x: 0.5, y: 0.5) > 180)

        // Darker, drawn without a build.
        fixture.setControl(.fill, [0.2, 0.2, 0.2, 1], ofClip: shape)
        var redrawn: Bool?
        let second = try await nextFrame(renderer) {
            redrawn = renderer.redraw(with: fixture.project, structure: fixture.project.structure, time: time, interactive: true)
        }
        #expect(redrawn == true)
        guard case .frame = second else { Issue.record("not drawn as a frame"); return }
        let fast = try level(second, x: 0.5, y: 0.5)
        #expect(fast < 80)

        // The same as a build of the edit draws.
        let rebuilt = try await fixture.build(forPreview: true)
        let check = LiveFrameRenderer()
        let full = try await nextFrame(check) { check.submit(.init(composed: rebuilt, scale: 1, time: time)) }
        #expect(abs(try level(full, x: 0.5, y: 0.5) - fast) < 4)
        #expect(abs(try level(full, x: 0.1, y: 0.1) - level(second, x: 0.1, y: 0.1)) < 4)
    }

    @Test func aStructuralEditOrAnotherMomentNeedsABuild() async throws {
        var (fixture, shape) = try await fixture()
        defer { fixture.cleanUp() }
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        let renderer = LiveFrameRenderer()
        let built = try await fixture.build(forPreview: true)
        _ = try await nextFrame(renderer) {
            renderer.submit(.init(composed: built, scale: 1, time: time, structure: fixture.project.structure))
        }
        let elsewhere = CMTime(seconds: 0.5, preferredTimescale: 600)
        #expect(!renderer.redraw(with: fixture.project, structure: fixture.project.structure, time: elsewhere, interactive: false))
        fixture.project.editClip(shape, in: fixture.timelineID) { $0.startOffset = CMTime(seconds: 0.25, preferredTimescale: 600) }
        #expect(!renderer.redraw(with: fixture.project, structure: fixture.project.structure, time: time, interactive: false))
    }
}
