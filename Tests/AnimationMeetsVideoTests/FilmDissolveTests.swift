import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct LumaRevealTests {
    @Test func aFilmDissolveRevealsBrightestFirst() {
        let early = LumaReveal(progress: 0.3, keysIncoming: true).gainAndBias
        func mask(_ luma: Double, _ gb: (gain: Double, bias: Double)) -> Double { min(max(gb.gain * luma + gb.bias, 0), 1) }
        #expect(mask(1, early) > mask(0.2, early))
        #expect(mask(1, LumaReveal(progress: 0, keysIncoming: true).gainAndBias) == 0)
        #expect(mask(0, LumaReveal(progress: 1, keysIncoming: true).gainAndBias) > 0.999)
    }
}

@Suite struct FilmDissolveRenderTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    private func media(_ url: URL, frames: Int) -> MediaClip {
        MediaClip(name: url.lastPathComponent, kind: .video, url: url, duration: CMTime(value: Int64(frames), timescale: 24),
                  frameRate: 24, colorSpace: .rec709, codecName: "H.264")
    }

    /// The gray level at a point of the frame, as a fraction of the size.
    private func gray(of composed: ComposedTimeline, at time: CMTime, x: Double = 0.5, y: Double = 0.5) async throws -> Int {
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
        let px = min(width - 1, Int(Double(width) * x)), py = min(height - 1, Int(Double(height) * y))
        return Int(pixels[(py * width + px) * 4 + 1])
    }

    private func makeMovies(_ dir: URL, incomingLuma: UInt8) async throws -> (under: URL, incoming: URL) {
        let under = dir.appending(path: "under-\(incomingLuma).mov")
        let incoming = dir.appending(path: "in-\(incomingLuma).mov")
        try await writeMovie(to: under, segments: [(luma: 128, frames: 96)])
        try await writeMovie(to: incoming, segments: [(luma: incomingLuma, frames: 72)])
        return (under, incoming)
    }

    /// Gray underneath; a clip of `incomingLuma` arriving at 1 s over two
    /// seconds with a linear `kind` transition.
    private func project(under: URL, incoming: URL, kind: TransitionKind) throws -> EditingProject {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        project.importClip(media(under, frames: 96), intoTimeline: t)
        let placed = project.importClip(media(incoming, frames: 72), intoTimeline: t)
        let top = try #require(placed)
        project.moveClip(top.clipID, in: t, layer: top.layerID, to: seconds(1))
        project.setTransition(kind, at: .leading, of: top.clipID, in: t, layer: top.layerID)
        project.setTransitionDuration(seconds(2), at: .leading, of: top.clipID, in: t, layer: top.layerID)
        return project
    }

    @Test func brightPartsOfTheNextClipComeThroughBeforeDarkOnes() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "amv-film-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bright = try await makeMovies(dir, incomingLuma: 230)
        let dark = try await makeMovies(dir, incomingLuma: 20)
        let brightProject = try project(under: bright.under, incoming: bright.incoming, kind: .filmDissolve)
        let darkProject = try project(under: dark.under, incoming: dark.incoming, kind: .filmDissolve)

        let brightComposed = try await CompositionExporter.buildComposedTimeline(for: brightProject, timelineID: brightProject.rootTimelineID)
        let darkComposed = try await CompositionExporter.buildComposedTimeline(for: darkProject, timelineID: darkProject.rootTimelineID)
        #expect(brightComposed.videoComposition?.customVideoCompositorClass == LayeredCompositor.self)

        // Halfway through, the bright clip is already in and the dark one
        // hasn't started to show; a plain dissolve would have both half in.
        let midway = seconds(2)
        #expect(abs(try await gray(of: brightComposed, at: midway) - 230) < 15)
        #expect(abs(try await gray(of: darkComposed, at: midway) - 128) < 15)
        // Before and after, each clip shows as itself.
        #expect(abs(try await gray(of: darkComposed, at: seconds(0.5)) - 128) < 15)
        #expect(abs(try await gray(of: darkComposed, at: seconds(3.5)) - 20) < 15)
    }

    @Test func theLayeredCompositorPlacesLayersLikeTheBuiltInOne() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "amv-film-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movies = try await makeMovies(dir, incomingLuma: 200)

        var project = EditingProject.empty
        let t = project.rootTimelineID
        let placed = project.importClip(media(movies.incoming, frames: 72), intoTimeline: t)
        let quarter = try #require(placed)
        // Half size, in the top left quarter.
        var transform = Effect(kind: .transform)
        transform.controls[0].number = AnimatedValue(ComponentValue(values: [-480, -270]))
        transform.controls[1].number = AnimatedValue(ComponentValue(values: [50, 50]))
        project.editClip(quarter.clipID, in: t) { $0.effects = [transform] }
        let builtIn = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t)
        #expect(builtIn.videoComposition?.customVideoCompositorClass == nil)

        // A film dissolve elsewhere in time switches the whole timeline over.
        let later = project.importClip(media(movies.under, frames: 96), intoTimeline: t)
        let other = try #require(later)
        project.moveClip(other.clipID, in: t, layer: other.layerID, to: seconds(4))
        project.setTransition(.filmDissolve, at: .leading, of: other.clipID, in: t, layer: other.layerID)
        let layered = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t)
        #expect(layered.videoComposition?.customVideoCompositorClass == LayeredCompositor.self)

        // The two draw the same picture.
        for (x, y) in [(0.1, 0.1), (0.25, 0.25), (0.45, 0.45), (0.25, 0.75), (0.75, 0.25), (0.75, 0.75)] {
            let expected = try await gray(of: builtIn, at: seconds(1), x: x, y: y)
            let drawn = try await gray(of: layered, at: seconds(1), x: x, y: y)
            #expect(abs(drawn - expected) <= 3)
            #expect(x < 0.5 && y < 0.5 ? drawn > 180 : drawn < 15)
        }
    }
}
