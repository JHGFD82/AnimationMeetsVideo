import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct MediaReplacerTests {
    private let pattern: [(amplitude: Float, seconds: Double)] = [
        (0.1, 1.0), (0.8, 2.0), (0.02, 0.5), (0.4, 1.5), (0.9, 1.0), (0.2, 2.5),
        (0.6, 0.7), (0.05, 1.3), (0.7, 1.8), (0.3, 1.2),
    ]

    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    }

    private struct Fixture {
        let directory: URL
        let original: URL
        var asset: MediaClip
        var reference: AssetReference
    }

    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "amv-replacer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appending(path: "original.wav")
        try writeTone(to: original, segments: pattern)
        let asset = try await MediaImporter.importClip(at: original)
        let reference = try await ReferenceCapture.capture(url: original)
        return Fixture(directory: directory, original: original, asset: asset, reference: reference)
    }

    @Test func aLateStartIsFoundFromTheAudio() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let replacement = fixture.directory.appending(path: "replacement.wav")
        try writeTone(to: replacement, segments: [(0, 1.5)] + pattern)

        let analysis = try await MediaReplacer.analyze(
            candidate: replacement, replacing: fixture.asset, reference: fixture.reference,
            originalScores: nil, usedRanges: [range(2, 8)]
        )

        #expect(analysis.hasReference)
        #expect(analysis.suggestion?.method == .audio)
        #expect(abs(analysis.proposedOffset.seconds - 1.5) < 0.02)
        #expect(!analysis.needsNoQuestions)
        guard case .needsConfirmation(let suggestion) = analysis.verdict else {
            Issue.record("a shifted file should ask for confirmation")
            return
        }
        #expect(suggestion?.isConfident == true)
        #expect(analysis.missingRanges.isEmpty)
    }

    @Test func theSameRecordingNeedsNoQuestions() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let replacement = fixture.directory.appending(path: "replacement.wav")
        try writeTone(to: replacement, segments: pattern)

        let analysis = try await MediaReplacer.analyze(
            candidate: replacement, replacing: fixture.asset, reference: fixture.reference,
            originalScores: nil, usedRanges: [range(2, 8)]
        )

        #expect(analysis.verdict == .aligned)
        #expect(analysis.proposedOffset == .zero)
        #expect(analysis.needsNoQuestions)
    }

    @Test func aMissingReferenceCannotBeCompared() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let replacement = fixture.directory.appending(path: "replacement.wav")
        try writeTone(to: replacement, segments: pattern)

        let analysis = try await MediaReplacer.analyze(
            candidate: replacement, replacing: fixture.asset, reference: nil,
            originalScores: nil, usedRanges: [range(2, 8)]
        )

        #expect(!analysis.hasReference)
        #expect(analysis.suggestion == nil)
        #expect(!analysis.needsNoQuestions)
    }

    @Test func aTooShortFileLeavesRangesMissing() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let replacement = fixture.directory.appending(path: "short.wav")
        try writeTone(to: replacement, segments: Array(pattern.prefix(5)))   // 6 s

        let analysis = try await MediaReplacer.analyze(
            candidate: replacement, replacing: fixture.asset, reference: fixture.reference,
            originalScores: nil, usedRanges: [range(2, 10)]
        )

        #expect(!analysis.missingRanges.isEmpty)
        #expect(analysis.report.blockers.contains { if case .missingRanges = $0 { true } else { false } })
        #expect(!analysis.missingRanges(forOffset: .zero).isEmpty)
        #expect(analysis.missingRanges(forOffset: .zero) == analysis.missingRanges)
    }

    @Test func aReplacementWithoutAudioIsABlocker() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let silentVideo = fixture.directory.appending(path: "silent.mov")
        try await writeMovie(to: silentVideo, segments: [(100, 240)])

        let analysis = try await MediaReplacer.analyze(
            candidate: silentVideo, replacing: fixture.asset, reference: fixture.reference,
            originalScores: nil, usedRanges: []
        )

        #expect(analysis.report.blockers.contains(.lostAudio))
    }

    @Test func silentVideoIsAlignedByItsCuts() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "amv-replacer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "original.mov")
        let replacement = directory.appending(path: "replacement.mov")
        try await writeMovie(to: original, segments: [(0, 24), (255, 36), (60, 24), (200, 48), (20, 24)])
        try await writeMovie(to: replacement, segments: [(0, 36), (255, 36), (60, 24), (200, 48), (20, 24)])

        let asset = try await MediaImporter.importClip(at: original)
        let reference = try await ReferenceCapture.capture(url: original)
        let scores = try await FrameScorer.score(url: original)

        let analysis = try await MediaReplacer.analyze(
            candidate: replacement, replacing: asset, reference: reference,
            originalScores: scores, usedRanges: [range(0, 5)]
        )

        #expect(analysis.suggestion?.method == .cuts)
        #expect(abs(analysis.proposedOffset.seconds - 0.5) < 0.05)
    }
}
