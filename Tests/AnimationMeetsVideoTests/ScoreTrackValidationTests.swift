import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ScoreTrackValidationTests {
    private func decoding(timescale: Int32 = 24, times: [Int64], scores: [UInt8]) throws -> ChangeScoreTrack {
        try ChangeScoreTrack(decoding: ChangeScoreTrack(timescale: timescale, times: times, scores: scores).encoded())
    }

    @Test func aWellFormedTrackLoads() throws {
        let track = try decoding(times: [0, 1, 2, 5], scores: [0, 255, 0, 7])
        #expect(track.frameCount == 4)
    }

    @Test func anEmptyTrackIsValid() throws {
        #expect(try decoding(times: [], scores: []).frameCount == 0)
    }

    @Test func aTrackThatStartsLateIsValid() throws {
        #expect(try decoding(times: [24, 25], scores: [0, 9]).frameCount == 2)
    }

    @Test func timesThatGoBackAreRejectedNotSorted() {
        #expect(throws: ChangeScoreTrackError.self) { try decoding(times: [0, 5, 3, 10], scores: [0, 9, 200, 9]) }
    }

    @Test func aRepeatedTimeIsRejectedNotMerged() {
        #expect(throws: ChangeScoreTrackError.self) { try decoding(times: [0, 3, 3, 10], scores: [0, 9, 200, 9]) }
    }

    @Test func aNegativeTimeIsRejected() {
        #expect(throws: ChangeScoreTrackError.self) { try decoding(times: [-1, 0, 1], scores: [0, 4, 4]) }
    }

    @Test func aFirstFrameWithAScoreIsRejected() {
        #expect(throws: ChangeScoreTrackError.self) { try decoding(times: [0, 1], scores: [3, 4]) }
    }

    @Test func aZeroTimescaleIsRejected() {
        #expect(throws: ChangeScoreTrackError.self) { try decoding(timescale: 0, times: [0, 1], scores: [0, 4]) }
    }

    @Test func everyScoreValueIsValid() throws {
        #expect(try decoding(times: [0, 1, 2], scores: [0, 0, 255]).frameCount == 3)
    }

    @Test func aSavedMalformedTrackIsRejectedForAnalyzingAgain() throws {
        let package = FileManager.default.temporaryDirectory.appending(path: "amv-valid-\(UUID().uuidString).amv")
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.preparePackage(at: package)
        let id = UUID(), stamp = FileStamp(byteCount: 1, modified: 1)
        // A record that fits the file, but a file that breaks the format.
        try ProjectStore.writeChangeScores(
            ChangeScoreTrack(timescale: 24, times: [0, 5, 3], scores: [0, 9, 200]), for: id, in: package, source: stamp
        )

        guard case .rejected(.damaged) = ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: stamp) else {
            Issue.record("the malformed track was accepted")
            return
        }
        #expect(ProjectStore.readChangeScores(for: id, in: package) == nil)
    }
}

@MainActor
@Suite struct ScoreTrackCommitTests {
    @Test func aMalformedTrackFromTheScorerIsAFailureNotAResult() async throws {
        var project = EditingProject.empty
        let clip = MediaClip(
            name: "a.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"),
            duration: CMTime(seconds: 1, preferredTimescale: 600), frameRate: 24, colorSpace: .rec709, codecName: "Test"
        )
        project.clips = [clip]
        let analysis = AssetAnalysis()
        analysis.backend.scoreFrames = { _, _ in ChangeScoreTrack(timescale: 24, times: [0, 4, 4], scores: [0, 9, 9]) }
        analysis.backend.captureReference = { _, _ in throw NSError(domain: "test", code: 1) }
        analysis.backend.capturePictures = { _, _, _ in ReferenceThumbnails(frames: []) }
        analysis.update(with: project)
        for _ in 0..<2000 where analysis.failure(.scenes, for: clip.id) == nil || !analysis.progress.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(analysis.tracks[clip.id] == nil)
        #expect(analysis.failure(.scenes, for: clip.id)?.kind == .corruptMedia)
        #expect(analysis.unsavedTracks.isEmpty)
    }
}
