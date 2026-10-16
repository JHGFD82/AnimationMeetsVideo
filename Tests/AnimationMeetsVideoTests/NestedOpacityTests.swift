import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct NestedOpacityTests {
    private func media(_ url: URL, frames: Int) -> MediaClip {
        MediaClip(name: url.lastPathComponent, kind: .video, url: url, duration: CMTime(value: Int64(frames), timescale: 24),
                  frameRate: 24, colorSpace: .rec709, codecName: "H.264")
    }

    /// The green level at the middle of the frame at `time`.
    private func gray(of composed: ComposedTimeline, at time: CMTime) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: composed.composition)
        generator.videoComposition = composed.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 192, height: 108)
        let image = try await generator.image(at: time).image
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Int(pixels[((height / 2) * width + width / 2) * 4 + 1])
    }

    /// A nested timeline of a dark layer over a bright one, both filling
    /// the frame, placed at `opacity` percent over black.
    private func project(dark: URL, bright: URL, opacity: Double) throws -> EditingProject {
        var project = EditingProject.empty
        let root = project.rootTimelineID
        let nested = project.addTimeline(name: "Nested", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        project.importClip(media(bright, frames: 48), intoTimeline: nested)
        project.importClip(media(dark, frames: 48), intoTimeline: nested)
        // Called first: #require can't wrap a mutating call.
        let embedded = project.embedTimeline(nested, intoTimeline: root)
        let placed = try #require(embedded)
        project.editTransform(of: placed.layerID, in: root) { $0.opacity.set(opacity, at: .zero) }
        return project
    }

    @Test func aFadedNestedTimelineFadesAsOnePicture() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "amv-nested-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dark = dir.appending(path: "dark.mov"), bright = dir.appending(path: "bright.mov")
        try await writeMovie(to: dark, segments: [(luma: 40, frames: 48)])
        try await writeMovie(to: bright, segments: [(luma: 240, frames: 48)])

        let faded = try project(dark: dark, bright: bright, opacity: 50)
        let composed = try await CompositionExporter.buildComposedTimeline(for: faded, timelineID: faded.rootTimelineID)
        #expect(composed.videoComposition?.customVideoCompositorClass == LayeredCompositor.self)
        // Only the dark layer shows, at half: the bright one under it must
        // not come through, as it would if each layer were faded alone.
        #expect(abs(try await gray(of: composed, at: CMTime(value: 12, timescale: 24)) - 20) < 12)

        // Without a fade, the built-in compositor draws it as before.
        let opaque = try project(dark: dark, bright: bright, opacity: 100)
        let plain = try await CompositionExporter.buildComposedTimeline(for: opaque, timelineID: opaque.rootTimelineID)
        #expect(plain.videoComposition?.customVideoCompositorClass == nil)
    }
}
