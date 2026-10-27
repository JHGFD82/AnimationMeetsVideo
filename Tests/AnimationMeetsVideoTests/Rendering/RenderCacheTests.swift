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
        project.setOpacity(50, ofClip: top.clipID, in: t)
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

        project.setOpacity(60, ofClip: top.clipID, in: t)
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

        // The item can instead draw the stretch from its clips, without
        // being built again, as a drag during playback needs.
        #expect(live.unrenderedVideoComposition == nil)
        var unrendered = cached
        unrendered.videoComposition = try #require(cached.unrenderedVideoComposition)
        let fromClips = try await centerGray(of: unrendered, at: time)
        #expect(abs(fromClips - expected) < 8)
    }

    @Test func aRenderOfAStretchEndingBetweenFramesIsStillUsed() async throws {
        // At 29.97 fps the clips' three seconds end between two frames, so
        // the render holds whole frames that don't add up to the stretch.
        let sandbox = try await RenderSandbox()
        defer { sandbox.cleanUp() }
        var (project, _, _) = try sandbox.stackedProject()
        project.timelines[0].frameRate = 29.97
        let t = project.rootTimelineID
        let cache = RenderCache(packageURL: sandbox.packageURL)

        let exported = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t)
        let needed = exported.segments.filter(\.needsRender)
        #expect(!needed.isEmpty)
        for segment in needed {
            try await SegmentRenderer.render(segment, from: exported, into: cache)
        }

        let cached = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t, forPreview: true, cache: cache)
        #expect(cached.cachedKeys == Set(needed.map(\.key)))
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

        // Asked for before the plan arrives, as a clip block may be.
        let cell = scheduler.progressCell(forClip: top.clipID)
        #expect(cell.value == nil)

        scheduler.setPlaying(true)
        scheduler.update(project: project, timelineID: t, segments: composed.segments)
        #expect(scheduler.progress(forClip: top.clipID) == 0)
        #expect(cell.value == 0)
        try await Task.sleep(for: .milliseconds(600))
        #expect(scheduler.finishedCount == 0)

        scheduler.setPlaying(false)
        for _ in 0..<400 where scheduler.finishedCount == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(scheduler.finishedCount == 1)
        #expect(scheduler.pending.isEmpty)
        #expect(scheduler.progress(forClip: top.clipID) == nil)
        #expect(cell.value == nil)
        #expect(scheduler.progressCell(forClip: top.clipID) === cell)
        let key = try #require(composed.segments.first(where: \.needsRender)?.key)
        #expect(scheduler.cache?.file(for: key) != nil)
    }

    @Test func doesNotRenderWhileADragHoldsTheMouseHoweverLongItRests() async throws {
        let sandbox = try await RenderSandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = try sandbox.stackedProject()
        let t = project.rootTimelineID
        let scheduler = RenderScheduler()
        scheduler.idleSeconds = 0.2
        scheduler.packageURL = sandbox.packageURL
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t, forPreview: true)

        scheduler.setInteracting(true)
        scheduler.update(project: project, timelineID: t, segments: composed.segments)
        // Three times the quiet it takes to start, with the pointer still.
        try await Task.sleep(for: .milliseconds(600))
        #expect(scheduler.finishedCount == 0)
        #expect(!scheduler.pending.isEmpty)

        // The quiet counts from the release.
        scheduler.setInteracting(false)
        for _ in 0..<400 where scheduler.finishedCount == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(scheduler.finishedCount == 1)
    }

    @Test func aRenderInProgressStopsWhenADragBegins() async throws {
        let sandbox = try await RenderSandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = try sandbox.stackedProject()
        let t = project.rootTimelineID
        let scheduler = RenderScheduler()
        scheduler.idleSeconds = 0.05
        scheduler.packageURL = sandbox.packageURL
        // A render that runs until it is stopped: a real one can finish
        // before the drag begins when the machine is busy.
        scheduler.render = { _, _, _, _ in try await Task.sleep(for: .seconds(60)) }
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t, forPreview: true)

        scheduler.update(project: project, timelineID: t, segments: composed.segments)
        for _ in 0..<400 where scheduler.active == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(scheduler.active != nil, "A render should have started")

        scheduler.setInteracting(true)
        // Cancelled, not finished: the segment is still to do.
        for _ in 0..<200 where scheduler.active != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(scheduler.active == nil)
        #expect(scheduler.finishedCount == 0)
        #expect(!scheduler.pending.isEmpty)
    }

    @Test func pendingRendersStartAtThePlayhead() {
        let scheduler = RenderScheduler()
        func segment(_ start: Int64, _ key: String) -> RenderSegment {
            RenderSegment(
                range: CMTimeRange(start: CMTime(value: start, timescale: 1), duration: CMTime(value: 1, timescale: 1)),
                key: key, needsRender: true, clipIDs: []
            )
        }
        scheduler.update(project: .empty, timelineID: UUID(), segments: [segment(0, "a"), segment(1, "b"), segment(2, "c"), segment(3, "d")])
        scheduler.playhead = CMTime(value: 2, timescale: 1)

        #expect(scheduler.pending.map(\.key) == ["c", "d", "a", "b"])
    }
}

extension EditingProject {
    /// Gives a clip a Transform effect holding only an Opacity of `percent`.
    mutating func setOpacity(_ percent: Double, ofClip clipID: UUID, in timelineID: UUID) {
        var effect = Effect(kind: .transform, controls: [EffectControl(kind: .opacity)])
        effect.controls[0].number = AnimatedValue(ComponentValue(values: [percent]))
        editClip(clipID, in: timelineID) { $0.effects = [effect] }
    }
}
