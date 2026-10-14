import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A scratch folder with two small gray movies and a package to cache into.
private struct RenderSandbox {
    let root: URL
    let dark: URL
    let light: URL
    let packageURL: URL

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "amv-render-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dark = root.appending(path: "dark.mov")
        light = root.appending(path: "light.mov")
        try await writeMovie(to: dark, segments: [(luma: 40, frames: 72)])
        try await writeMovie(to: light, segments: [(luma: 220, frames: 72)])
        packageURL = root.appending(path: "Test.amv", directoryHint: .isDirectory)
        try ProjectStore.preparePackage(at: packageURL)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func media(_ url: URL) -> MediaClip {
        MediaClip(name: url.lastPathComponent, kind: .video, url: url, duration: CMTime(value: 72, timescale: 24),
                  frameRate: 24, colorSpace: .rec709, codecName: "H.264")
    }

    /// The light movie at half opacity over the dark one, in a frame the
    /// size of the movies so renders stay small.
    func stackedProject() throws -> (project: EditingProject, top: (layerID: UUID, clipID: UUID), bottom: (layerID: UUID, clipID: UUID)) {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        project.timelines[0].frameSize = CGSize(width: 128, height: 72)
        let placedBottom = project.importClip(media(dark), intoTimeline: t)
        let placedTop = project.importClip(media(light), intoTimeline: t)
        let bottom = try #require(placedBottom)
        let top = try #require(placedTop)
        project.editTransform(of: top.layerID, in: t) { $0.opacity.set(50, at: .zero) }
        return (project, top, bottom)
    }

    func singleClipProject() throws -> EditingProject {
        var project = EditingProject.empty
        project.timelines[0].frameSize = CGSize(width: 128, height: 72)
        let placed = project.importClip(media(dark), intoTimeline: project.rootTimelineID)
        _ = try #require(placed)
        return project
    }
}

/// The green level at the center of the frame at `time`.
private func centerGray(of composed: ComposedTimeline, at time: CMTime) async throws -> Int {
    try await centerGray(of: composed.composition, videoComposition: composed.videoComposition, at: time)
}

private func centerGray(of asset: AVAsset, videoComposition: AVVideoComposition? = nil, at time: CMTime) async throws -> Int {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.videoComposition = videoComposition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try await generator.image(at: time).image
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try #require(CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
    return Int(pixel[1])
}

@Suite struct RenderPlanTests {
    @Test func aSingleUntouchedClipNeedsNoRender() async throws {
        let sandbox = try await RenderSandbox()
        defer { sandbox.cleanUp() }
        let project = try sandbox.singleClipProject()

        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)

        #expect(!composed.segments.isEmpty)
        #expect(composed.segments.allSatisfy { !$0.needsRender })
    }

    @Test func stackedLayersNeedRenderingInShortPiecesNamingTheirClips() async throws {
        let sandbox = try await RenderSandbox()
        defer { sandbox.cleanUp() }
        let (project, top, bottom) = try sandbox.stackedProject()

        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        let rendered = composed.segments.filter(\.needsRender)

        // Three seconds at 24 fps is 72 frames, under one piece.
        #expect(rendered.count == 1)
        #expect(rendered.first?.clipIDs == [top.clipID, bottom.clipID])
        #expect(rendered.first?.key.count == 32)
        let frames = try #require(rendered.first).range.duration.seconds * 24
        #expect(frames <= Double(RenderSegment.maxFrames))
    }

    @Test func movingEverythingKeepsTheKeyAndChangingTheLookDoesNot() async throws {
        let sandbox = try await RenderSandbox()
        defer { sandbox.cleanUp() }
        var (project, top, bottom) = try sandbox.stackedProject()
        let t = project.rootTimelineID
        func key(_ project: EditingProject) async throws -> String? {
            try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t).segments.first(where: \.needsRender)?.key
        }
        let original = try await key(project)

        let later = CMTime(value: 48, timescale: 24)
        project.moveClip(bottom.clipID, in: t, layer: bottom.layerID, to: later)
        project.moveClip(top.clipID, in: t, layer: top.layerID, to: later)
        #expect(try await key(project) == original)

        project.editTransform(of: top.layerID, in: t) { $0.opacity.set(60, at: .zero) }
        #expect(try await key(project) != original)
    }
}

@Suite struct RenderCacheTests {
    @Test func aRenderedSegmentPlaysFromTheCacheAndLooksTheSame() async throws {
        let sandbox = try await RenderSandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = try sandbox.stackedProject()
        let t = project.rootTimelineID
        let cache = RenderCache(packageURL: sandbox.packageURL)

        let exported = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t)
        let firstRendered = exported.segments.first(where: \.needsRender)
        let segment = try #require(firstRendered)
        try await SegmentRenderer.render(segment, from: exported, into: cache)
        #expect(cache.file(for: segment.key) != nil)

        let live = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t, forPreview: true)
        let cached = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t, forPreview: true, cache: cache)
        #expect(live.cachedKeys.isEmpty)
        #expect(cached.cachedKeys == [segment.key])

        let time = CMTime(value: 30, timescale: 24)
        let expected = try await centerGray(of: live, at: time)
        let drawn = try await centerGray(of: cached, at: time)
        #expect(expected > 100 && expected < 160)
        #expect(abs(drawn - expected) < 8)
    }

    @Test func a422ExportReusesRendersAndA4444ExportDoesNot() async throws {
        let sandbox = try await RenderSandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = try sandbox.stackedProject()
        let t = project.rootTimelineID
        let cache = RenderCache(packageURL: sandbox.packageURL)
        let exported = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t)
        let firstRendered = exported.segments.first(where: \.needsRender)
        try await SegmentRenderer.render(try #require(firstRendered), from: exported, into: cache)

        let fast = sandbox.root.appending(path: "fast.mov")
        let full = sandbox.root.appending(path: "full.mov")
        let reused = try await CompositionExporter.export(project: project, timelineID: t, preset: .proRes422, to: fast, cache: cache)
        let notReused = try await CompositionExporter.export(project: project, timelineID: t, preset: .proRes4444, to: full, cache: cache)

        #expect(reused == 1)
        #expect(notReused == 0)
        let live = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t)
        let time = CMTime(value: 30, timescale: 24)
        let expected = try await centerGray(of: live, at: time)
        let fromRender = try await centerGray(of: AVURLAsset(url: fast), at: time)
        #expect(abs(fromRender - expected) < 8)
    }

    @Test func evictionDropsTheLeastRecentlyUsedFirstAndSparesKeptKeys() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amv-evict-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RenderCache(packageURL: root)
        for (index, key) in ["old", "kept", "new"].enumerated() {
            let partial = try cache.partialURL(for: key)
            try Data(count: 100).write(to: partial)
            try cache.finish(key)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 60)], ofItemAtPath: cache.url(for: key).path
            )
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: cache.url(for: "kept").path)

        cache.evict(toFit: 150, keeping: ["kept"])

        #expect(cache.file(for: "old") == nil)
        #expect(cache.file(for: "kept") != nil)
        #expect(cache.file(for: "new") == nil)
    }

    @Test func leftoverPartialsAreRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amv-partial-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RenderCache(packageURL: root)
        try Data(count: 10).write(to: try cache.partialURL(for: "abandoned"))

        cache.removePartials()

        let partial = try cache.partialURL(for: "abandoned")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }
}

@MainActor
@Suite struct RenderSchedulerTests {
    @Test func rendersWhatThePlanNeedsOnceIdleAndNotWhilePlaying() async throws {
        let sandbox = try await RenderSandbox()
        defer { sandbox.cleanUp() }
        let (project, top, _) = try sandbox.stackedProject()
        let t = project.rootTimelineID
        let scheduler = RenderScheduler()
        scheduler.idleSeconds = 0.2
        scheduler.packageURL = sandbox.packageURL
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t, forPreview: true)

        scheduler.setPlaying(true)
        scheduler.update(project: project, timelineID: t, segments: composed.segments)
        #expect(scheduler.progress(forClip: top.clipID) == 0)
        try await Task.sleep(for: .milliseconds(600))
        #expect(scheduler.finishedCount == 0)

        scheduler.setPlaying(false)
        for _ in 0..<400 where scheduler.finishedCount == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(scheduler.finishedCount == 1)
        #expect(scheduler.pending.isEmpty)
        #expect(scheduler.progress(forClip: top.clipID) == nil)
        let key = try #require(composed.segments.first(where: \.needsRender)?.key)
        #expect(scheduler.cache?.file(for: key) != nil)
    }
}
