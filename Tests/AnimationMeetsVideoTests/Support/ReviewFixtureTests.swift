import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The review's generated fixtures (`ReviewFixtures`) read back as made:
/// frame numbers from the pictures, clicks at their samples, and the dense
/// edit through a save. The first three run always and are small; the
/// last writes the whole set to `REVIEW_FIXTURES` (a folder outside the
/// repository) for benchmarks (`AMV_PROJECT`) and review by hand.
@Suite(.serialized) struct ReviewFixtureTests {
    private func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "amv-review-\(UUID().uuidString)-\(name)")
    }

    /// The frame shown at `time`, read from its barcode, decoded exactly.
    private func frameNumber(of url: URL, at time: CMTime) async throws -> Int? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: time).image
        return ReviewFixtures.frameNumber(in: image)
    }

    @Test(arguments: [CMTime(value: 1, timescale: 24), CMTime(value: 1001, timescale: 24000)])
    func aNumberedLongGOPMovieShowsEachFrameItsOwnNumber(duration: CMTime) async throws {
        let url = temporary("numbered.mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ReviewFixtures.writeMovie(
            to: url, picture: .flashes(every: 12, hold: 2), timing: .constant(duration), count: 48, keyFrameInterval: 48
        )
        // Across the group of pictures: the key frame, the ones after it,
        // a flash, the last.
        for index in [0, 1, 11, 12, 25, 47] {
            let shown = try await frameNumber(of: url, at: CMTimeMultiply(duration, multiplier: Int32(index)))
            #expect(shown == index, "frame \(index) at \(duration.value)/\(duration.timescale)")
        }
    }

    @Test func aVariableRateMovieShowsTheFramePresentedThen() async throws {
        let url = temporary("vfr.mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let timing = ReviewFixtures.Timing.variable([CMTime(value: 1, timescale: 30), CMTime(value: 1, timescale: 60), CMTime(value: 1, timescale: 20)])
        try await ReviewFixtures.writeMovie(to: url, picture: .held(hold: 1), timing: timing, count: 30, keyFrameInterval: 30)
        let times = ReviewFixtures.times(timing, count: 30)
        for index in [0, 1, 2, 7, 29] {
            #expect(try await frameNumber(of: url, at: times[index]) == index)
        }
    }

    @Test func clicksStartOnTheSampleTheirFrameDoes() throws {
        let duration = CMTime(value: 1001, timescale: 24000)
        #expect(ReviewFixtures.sample(ofFrame: 12, duration: duration) == 12 * 2002)
        let url = temporary("clicks.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let at = [0, 12, 24].map { ReviewFixtures.sample(ofFrame: $0, duration: duration) }
        try ReviewFixtures.writeClicks(to: url, at: at, seconds: 2)
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try #require(buffer.floatChannelData?[0])
        // Each click begins on its sample: silent just before, loud on it.
        for start in at {
            #expect(data[start] > 0.5)
            if start > 0 { #expect(data[start - 1] == 0) }
        }
    }

    @Test func theDenseEditSavesAndOpensWhole() async throws {
        let movie = temporary("dense-source.mov")
        let package = temporary("Dense.amv")
        defer {
            try? FileManager.default.removeItem(at: movie)
            try? FileManager.default.removeItem(at: package)
        }
        try await ReviewFixtures.writeMovie(to: movie, picture: .held(hold: 2), timing: .constant(CMTime(value: 1, timescale: 24)), count: 240)
        let media = MediaClip(
            name: "Numbered", kind: .video, url: movie, duration: CMTime(value: 240, timescale: 24), frameRate: 24,
            colorSpace: .rec709, codecName: "H.264"
        )
        var song = MediaClip(
            name: "Clicks", kind: .audio, url: URL(fileURLWithPath: "/dev/null"), duration: CMTime(value: 60, timescale: 1), frameRate: 0,
            colorSpace: .rec709, codecName: "PCM"
        )
        song.hasAudio = true
        let project = try ReviewFixtures.denseProject(media: media, song: song, clipCount: 320)
        // The cuts, not the song under them.
        func cuts(_ project: EditingProject) -> Int {
            project.timeline(id: project.rootTimelineID)?.layers.flatMap(\.clips).filter { $0.source == .media(media.id) }.count ?? 0
        }
        #expect(cuts(project) == 320)
        try await ProjectStore.save(project, to: package)
        let songClip = song
        let loaded = try await ProjectStore.load(from: package) { url in
            url == movie ? media : songClip
        }
        #expect(cuts(loaded.project) == 320)
    }

    /// The whole set, written to `REVIEW_FIXTURES`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REVIEW_FIXTURES"] != nil), .timeLimit(.minutes(10)))
    func makeTheReviewSet() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["REVIEW_FIXTURES"]), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let count = 240
        for rate in ReviewFixtures.rates {
            let flashes = 24
            try await ReviewFixtures.writeMovie(
                to: folder.appending(path: "numbered-\(rate.name).mov"), picture: .flashes(every: flashes, hold: 2),
                timing: .constant(rate.duration), count: count
            )
            let at = stride(from: 0, to: count, by: flashes).map { ReviewFixtures.sample(ofFrame: $0, duration: rate.duration) }
            let seconds = Double(count) * Double(rate.duration.value) / Double(rate.duration.timescale)
            try ReviewFixtures.writeClicks(to: folder.appending(path: "clicks-\(rate.name).wav"), at: at, seconds: seconds)
        }
        let film = CMTime(value: 1, timescale: 24)
        try await ReviewFixtures.writeMovie(to: folder.appending(path: "held-threes.mov"), picture: .held(hold: 3), timing: .constant(film), count: count)
        try await ReviewFixtures.writeMovie(to: folder.appending(path: "fade.mov"), picture: .fade(length: 48), timing: .constant(film), count: count)
        try await ReviewFixtures.writeMovie(to: folder.appending(path: "gradient.mov"), picture: .gradient, timing: .constant(film), count: count)
        try await ReviewFixtures.writeMovie(to: folder.appending(path: "outlines.mov"), picture: .outlines, timing: .constant(film), count: count)
        try await ReviewFixtures.writeMovie(
            to: folder.appending(path: "vfr.mov"), picture: .held(hold: 1),
            timing: .variable([CMTime(value: 1, timescale: 30), CMTime(value: 1, timescale: 60), CMTime(value: 1, timescale: 20)]), count: count
        )
        // A song of clicks at 120 beats a minute, a minute long.
        let song = folder.appending(path: "song-120bpm.wav")
        try ReviewFixtures.writeClicks(to: song, at: stride(from: 0, to: 60 * 48_000, by: 24_000).map { $0 }, seconds: 60)

        let numbered = folder.appending(path: "numbered-24.mov")
        let media = try await MediaImporter.importClip(at: numbered, packageURL: nil)
        let music = try await MediaImporter.importClip(at: song, packageURL: nil)
        let project = try ReviewFixtures.denseProject(media: media, song: music, clipCount: 320)
        try await ProjectStore.save(project, to: folder.appending(path: "Dense review edit.amv", directoryHint: .isDirectory))
    }
}
