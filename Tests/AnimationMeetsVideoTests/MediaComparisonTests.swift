import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct MediaComparisonTests {
    private func snapshot(
        width: Int = 1920, height: Int = 1080, frameRate: Double = 24,
        isVideo: Bool = true, audio: Bool = true, transfer: String? = "ITU_R_709_2"
    ) -> AssetMetadataSnapshot {
        AssetMetadataSnapshot(
            fileName: "a.mov", originalPath: "/tmp/a.mov", byteCount: 1, modified: 1,
            isVideo: isVideo, durationValue: 600, durationTimescale: 24,
            frameRate: frameRate, width: width, height: height, codecName: "H.264",
            colorPrimaries: transfer == nil ? nil : "ITU_R_709_2",
            colorTransfer: transfer,
            colorMatrix: transfer == nil ? nil : "ITU_R_709_2",
            audioSampleRate: audio ? 48000 : nil, capturedAt: 0
        )
    }

    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    }

    @Test func identicalFilesAreClean() {
        #expect(MediaComparison.compare(old: snapshot(), new: snapshot()) == MediaComparison.Report())
    }

    @Test func aResolutionChangeIsAdjustedSilently() {
        let report = MediaComparison.compare(old: snapshot(), new: snapshot(width: 3840, height: 2160))
        #expect(report.isClean)
        #expect(report.adjustments.count == 1)
    }

    @Test func aFrameRateChangeIsAdjustedSilently() {
        let report = MediaComparison.compare(old: snapshot(), new: snapshot(frameRate: 23.976))
        #expect(report.isClean)
        #expect(report.adjustments.count == 1)
    }

    @Test func anAspectRatioChangeNeedsConfirmation() {
        let report = MediaComparison.compare(old: snapshot(), new: snapshot(width: 1440, height: 1080))
        #expect(report.confirmations.count == 1)
        guard case .aspectRatio = report.confirmations.first else {
            Issue.record("expected an aspect ratio confirmation")
            return
        }
    }

    @Test func hdrToSdrNeedsConfirmation() {
        let report = MediaComparison.compare(old: snapshot(transfer: "SMPTE_ST_2084_PQ"), new: snapshot())
        #expect(report.confirmations == [.dynamicRange(oldIsHDR: true, newIsHDR: false)])
    }

    @Test func untaggedColorNeedsConfirmation() {
        let report = MediaComparison.compare(old: snapshot(), new: snapshot(transfer: nil))
        #expect(report.confirmations.contains(.untaggedColor))
    }

    @Test func losingAudioOrVideoBlocks() {
        #expect(MediaComparison.compare(old: snapshot(), new: snapshot(audio: false)).blockers == [.lostAudio])
        #expect(MediaComparison.compare(old: snapshot(), new: snapshot(isVideo: false, audio: true)).blockers == [.lostVideo])
    }

    @Test func anAudioFileHasNoPictureDifferences() {
        let old = snapshot(width: 0, height: 0, isVideo: false, transfer: nil)
        let new = snapshot(width: 0, height: 0, isVideo: false, transfer: nil)
        #expect(MediaComparison.compare(old: old, new: new).isClean)
    }

    @Test func rangesInsideTheNewFileAreNotMissing() {
        let missing = MediaComparison.missingRanges(
            used: [range(2, 10), range(20, 30)], offset: .zero,
            newDuration: CMTime(seconds: 30, preferredTimescale: 600)
        )
        #expect(missing.isEmpty)
    }

    @Test func aShortNewFileLeavesTheTailMissing() {
        let missing = MediaComparison.missingRanges(
            used: [range(2, 10), range(20, 30)], offset: .zero,
            newDuration: CMTime(seconds: 25, preferredTimescale: 600)
        )
        #expect(missing == [range(25, 30)])
    }

    @Test func anOffsetCanPushTheHeadBeforeTheStart() {
        // The new file starts 3 s into the original, so original 2...10 is
        // only available from 3 s.
        let missing = MediaComparison.missingRanges(
            used: [range(2, 10)], offset: CMTime(seconds: -3, preferredTimescale: 600),
            newDuration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        #expect(missing == [range(2, 3)])
    }

    @Test func anOffsetCanPushTheTailPastTheEnd() {
        let missing = MediaComparison.missingRanges(
            used: [range(0, 10)], offset: CMTime(seconds: 5, preferredTimescale: 600),
            newDuration: CMTime(seconds: 12, preferredTimescale: 600)
        )
        #expect(missing == [range(7, 10)])
    }
}

@Suite struct SyncVerdictTests {
    private let tolerance = CMTime(value: 1, timescale: 24)

    private func suggestion(_ seconds: Double, confidence: Double) -> AlignmentSuggestion {
        AlignmentSuggestion(offset: CMTime(seconds: seconds, preferredTimescale: 600), method: .audio, confidence: confidence)
    }

    @Test func aConfidentMatchAtTheCurrentOffsetIsAligned() {
        let verdict = SyncVerdict.decide(suggestion: suggestion(0.01, confidence: 0.8), currentOffset: .zero, tolerance: tolerance)
        #expect(verdict == .aligned)
    }

    @Test func aConfidentMatchAtAnotherOffsetAsksWithTheSuggestion() {
        let found = suggestion(2, confidence: 0.8)
        let verdict = SyncVerdict.decide(suggestion: found, currentOffset: .zero, tolerance: tolerance)
        #expect(verdict == .needsConfirmation(suggestion: found))
    }

    @Test func aWeakMatchAsks() {
        let found = suggestion(0, confidence: 0.05)
        let verdict = SyncVerdict.decide(suggestion: found, currentOffset: .zero, tolerance: tolerance)
        #expect(verdict == .needsConfirmation(suggestion: found))
    }

    @Test func noMatchAsksWithoutASuggestion() {
        let verdict = SyncVerdict.decide(suggestion: nil, currentOffset: .zero, tolerance: tolerance)
        #expect(verdict == .needsConfirmation(suggestion: nil))
    }
}
