import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Footage whose frames are stamped on a coarse track timescale, as a
/// Matroska file remuxed to MP4 (1 ms) or an MPEG-TS file (90 kHz) is: a
/// frame stamped a hair after its frame time was shown from that stamp on,
/// so at its own frame time the one before still showed, and frames were
/// shown twice and others never (code-review-notes.md, F91).
@Suite struct RoundedFrameTimeTests {
    private static let frame = CMTime(value: 1001, timescale: 24_000)

    private func framesShown(timescale: CMTimeScale, count: Int) async throws -> [Int?] {
        let directory = FileManager.default.temporaryDirectory.appending(path: "amv-rounded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "rounded.mov")
        try await ReviewFixtures.writeMovie(
            to: url, picture: .held(hold: 1), timing: .constant(Self.frame), count: count, keyFrameInterval: 12,
            mediaTimeScale: timescale
        )
        var project = EditingProject.empty
        project.timelines[0].frameSize = CGSize(width: ReviewFixtures.width, height: ReviewFixtures.height)
        project.timelines[0].frameRate = 24_000.0 / 1001
        let media = MediaClip(
            name: "Rounded", kind: .video, url: url, duration: CMTimeMultiply(Self.frame, multiplier: Int32(count)),
            frameRate: 24_000.0 / 1001, colorSpace: .rec709, codecName: "H.264"
        )
        let placed = project.importClip(media, intoTimeline: project.rootTimelineID)
        _ = try #require(placed)
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)

        let generator = AVAssetImageGenerator(asset: composed.composition)
        generator.videoComposition = composed.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var shown: [Int?] = []
        for index in 0..<count {
            let image = try await generator.image(at: CMTimeMultiply(Self.frame, multiplier: Int32(index))).image
            shown.append(ReviewFixtures.frameNumber(in: image))
        }
        return shown
    }

    @Test(arguments: [1000, 90_000, 600] as [CMTimeScale])
    func eachTimelineFrameShowsItsOwnFrameOfRoundedFootage(timescale: CMTimeScale) async throws {
        let count = 30
        let shown = try await framesShown(timescale: timescale, count: count)
        #expect(shown == (0..<count).map { $0 }, "at \(timescale): \(shown.map { $0.map(String.init) ?? "?" }.joined(separator: " "))")
    }

    @Test func theNudgeIsATickAndNeverMoreThanAQuarterFrame() {
        #expect(MediaTrackCache.readNudge(timescale: 1000, frameRate: 23.976) == CMTime(value: 1, timescale: 1000))
        #expect(MediaTrackCache.readNudge(timescale: 24, frameRate: 24) == CMTime(seconds: 0.25 / 24, preferredTimescale: 1_000_000))
        #expect(MediaTrackCache.readNudge(timescale: 0, frameRate: 24) == .zero)
    }
}
