import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The viewer's paused frame drawn again with new values from what the last
/// build decoded (`LiveFrameRenderer.redraw`), as dragging a value does.
@MainActor @Suite struct LiveRedrawTests {
    /// The green level at a point of `image`, as fractions from the top left.
    private func level(_ image: CGImage, x: Double, y: Double) throws -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let px = min(width - 1, Int(Double(width) * x)), py = min(height - 1, Int(Double(height) * y))
        return Int(pixels[(py * width + px) * 4 + 1])
    }

    /// The next frame the renderer draws.
    private func nextFrame(_ renderer: LiveFrameRenderer, _ start: () -> Void) async throws -> CGImage {
        let frame: CGImage? = await withCheckedContinuation { continuation in
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
