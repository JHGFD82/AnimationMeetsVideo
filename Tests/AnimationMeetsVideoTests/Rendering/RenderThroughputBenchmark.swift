import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Times rendering a heavy timeline into the render cache, a piece at a
/// time and several pieces at once, and exporting it whole without the
/// cache for comparison. Its footage is three 1080p H.264 movies of a
/// moving pattern, written once per run; each workload stacks them:
///
/// - `blur`: every layer blurred and graded, the top two at 70% opacity.
/// - `motion`: `blur`, with the top layer moving and motion blurred.
///
/// Every row renders into an empty cache. Prints a table of the fastest
/// and median seconds over the runs for the whole timeline, and the median
/// seconds until the first piece (the one at the playhead, which plays
/// next) was ready, since pieces sharing the GPU each take longer; nothing
/// is asserted, since timings vary too much from machine to machine for CI.
///
/// Runs only with `RENDER_BENCHMARK` set: `all`, or workload names
/// separated by commas. `RENDER_BENCHMARK_SECONDS` sets the timeline's
/// length (16 by default: four 96-frame pieces), `RENDER_BENCHMARK_RUNS`
/// how many times each row runs (3 by default). Release timings are the
/// ones that matter:
///
///     swift build -c release -Xswiftc -enable-testing --build-tests
///     RENDER_BENCHMARK=all swift test -c release -Xswiftc -enable-testing \
///         --skip-build --filter RenderThroughputBenchmark
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RENDER_BENCHMARK"] != nil))
struct RenderThroughputBenchmark {
    enum Workload: String, CaseIterable {
        case blur, motion
    }

    private static let environment = ProcessInfo.processInfo.environment
    private static let seconds = Int(environment["RENDER_BENCHMARK_SECONDS"] ?? "") ?? 16
    private static let runs = max(1, Int(environment["RENDER_BENCHMARK_RUNS"] ?? "") ?? 3)
    private static let fps: Int32 = 24
    private static let size = CGSize(width: 1920, height: 1080)

    @Test func renderThroughput() async throws {
        let wanted = Self.environment["RENDER_BENCHMARK"] ?? "all"
        let names = Set(wanted.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let workloads = Workload.allCases.filter { names.contains("all") || names.contains($0.rawValue) }
        try #require(!workloads.isEmpty, "No workload named \(wanted)")

        let root = FileManager.default.temporaryDirectory.appending(path: "amv-render-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = Self.seconds * Int(Self.fps)
        var sources: [MediaClip] = []
        for index in 0..<3 {
            let url = root.appending(path: "source-\(index).mov")
            try await Self.writePattern(to: url, frames: frames, phase: index * 85)
            sources.append(MediaClip(
                name: url.lastPathComponent, kind: .video, url: url,
                duration: CMTime(value: Int64(frames), timescale: Self.fps),
                frameRate: Double(Self.fps), colorSpace: .rec709, codecName: "H.264"
            ))
        }

        var rows: [String] = []
        for workload in workloads {
            let project = try Self.project(workload, sources: sources)
            let t = project.rootTimelineID
            let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t)
            let pieces = composed.segments.filter(\.needsRender)
            let renderedFrames = pieces.reduce(0.0) { $0 + $1.range.duration.seconds } * Double(Self.fps)
            try #require(!pieces.isEmpty, "\(workload) needs no render")

            for concurrency in 1...3 {
                let times = try await measure(root: root) { cache in
                    let first = try await Self.render(pieces, from: composed, into: cache, concurrency: concurrency)
                    #expect(pieces.allSatisfy { cache.file(for: $0.key) != nil })
                    return first
                }
                rows.append(Self.row(workload, "\(concurrency) at once", pieces.count, renderedFrames, times))
            }
            let exportTimes = try await measure(root: root) { _ in
                let url = root.appending(path: "export.mov")
                _ = try await CompositionExporter.export(project: project, timelineID: t, preset: .proRes422, to: url)
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            rows.append(Self.row(workload, "export, no cache", pieces.count, Double(frames), exportTimes))
        }

        print("RenderThroughputBenchmark (\(Self.seconds) s of 1080p at \(Self.fps) fps, \(Self.runs) runs, \(ProcessInfo.processInfo.activeProcessorCount) cores)")
        print("workload  how                 pieces   frames   fastest s   median s   fps (fastest)   first piece s")
        for row in rows { print(row) }
    }

    // MARK: Measuring

    /// One run: seconds for all of it, and until the first piece was ready.
    struct Timing {
        var total: Double
        var first: Double?
    }

    /// Runs `body` `runs` times, each with an empty cache in a new package.
    /// `body` returns when the first piece was ready, if it renders pieces.
    private func measure(
        root: URL, _ body: (RenderCache) async throws -> ContinuousClock.Instant?
    ) async throws -> [Timing] {
        var times: [Timing] = []
        for _ in 0..<Self.runs {
            let packageURL = root.appending(path: "Bench-\(UUID().uuidString).amv", directoryHint: .isDirectory)
            try ProjectStore.preparePackage(at: packageURL)
            defer { try? FileManager.default.removeItem(at: packageURL) }
            let started = ContinuousClock.now
            let first = try await body(RenderCache(packageURL: packageURL))
            let ended = ContinuousClock.now
            times.append(Timing(total: Self.inSeconds(ended - started), first: first.map { Self.inSeconds($0 - started) }))
        }
        return times
    }

    private static func inSeconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Renders every piece, `concurrency` at a time, in order, and returns
    /// when the first was ready.
    private static func render(
        _ pieces: [RenderSegment], from composed: ComposedTimeline, into cache: RenderCache, concurrency: Int
    ) async throws -> ContinuousClock.Instant? {
        try await withThrowingTaskGroup(of: Int.self) { group in
            var next = pieces.enumerated().makeIterator()
            func add(_ item: (offset: Int, element: RenderSegment)) {
                group.addTask {
                    try await SegmentRenderer.render(item.element, from: composed, into: cache)
                    return item.offset
                }
            }
            for _ in 0..<concurrency {
                guard let item = next.next() else { break }
                add(item)
            }
            var first: ContinuousClock.Instant?
            while let done = try await group.next() {
                if done == 0 { first = .now }
                if let item = next.next() { add(item) }
            }
            return first
        }
    }

    private static func row(_ workload: Workload, _ how: String, _ pieces: Int, _ frames: Double, _ times: [Timing]) -> String {
        let totals = times.map(\.total).sorted()
        let fastest = totals[0], median = totals[totals.count / 2]
        let firsts = times.compactMap(\.first).sorted()
        let first = firsts.isEmpty ? "" : String(format: "%16.2f", firsts[firsts.count / 2])
        return workload.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            + how.padding(toLength: 20, withPad: " ", startingAt: 0)
            + String(format: "%6d %8.0f %11.2f %10.2f %15.1f", pieces, frames, fastest, median, frames / fastest)
            + first
    }

    // MARK: The timeline

    private static func project(_ workload: Workload, sources: [MediaClip]) throws -> EditingProject {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        project.timelines[0].frameSize = size
        var placed: [(layerID: UUID, clipID: UUID)] = []
        for source in sources {
            let clip = project.importClip(source, intoTimeline: t)
            placed.append(try #require(clip))
        }
        for (index, clip) in placed.enumerated() {
            // First, since it replaces the clip's stack.
            if index > 0 { project.setOpacity(70, ofClip: clip.clipID, in: t) }
            let blur = project.addEffect(EffectKind(package: "gaussianBlur"), toClip: clip.clipID, in: t)
            try #require(blur != nil, "Couldn't add a blur")
            var grade = Effect(kind: .color, controls: [EffectControl(kind: .exposure)])
            grade.controls[0].number = AnimatedValue(ComponentValue(values: [0.3]))
            project.editClip(clip.clipID, in: t) { $0.effects.append(grade) }
        }
        if workload == .motion, let top = placed.last {
            var move = Effect(kind: .transform, controls: [EffectControl(kind: .position)])
            move.controls[0].number.setAnimated(true, at: .zero)
            move.controls[0].number.set(ComponentValue(values: [600, 200]), at: CMTime(value: Int64(seconds), timescale: 1))
            project.editClip(top.clipID, in: t) {
                $0.effects.append(move)
                $0.shutter.motionBlur = MotionBlur()
            }
        }
        return project
    }

    /// A 1080p H.264 movie of diagonal color bands moving down and across,
    /// so it has detail to decode and blur. `phase` shifts the bands, so
    /// each source differs.
    private static func writePattern(to url: URL, frames: Int, phase: Int) async throws {
        let width = Int(size.width), height = Int(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        try #require(writer.startWriting(), "\(writer.error?.localizedDescription ?? "couldn't start writing")")
        writer.startSession(atSourceTime: .zero)

        // One period of bands, long enough that any row is a slice of it.
        let period = 256
        var band = [UInt8](repeating: 255, count: (width + period) * 4)
        for x in 0..<(width + period) {
            let i = (x + phase) % period
            band[x * 4] = UInt8(i)
            band[x * 4 + 1] = UInt8(255 - i)
            band[x * 4 + 2] = UInt8((i * 3) & 255)
        }
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try #require(writer.status != .failed, "\(writer.error?.localizedDescription ?? "writing failed")")
                try await Task.sleep(for: .milliseconds(2))
            }
            let pool = try #require(adaptor.pixelBufferPool)
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            let buffer = try #require(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            band.withUnsafeBytes { bands in
                for y in 0..<height {
                    let offset = (y * 2 + frame * 4) % period
                    memcpy(base + y * bytesPerRow, bands.baseAddress! + offset * 4, width * 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(writer.error?.localizedDescription ?? "writing didn't complete")")
    }
}
