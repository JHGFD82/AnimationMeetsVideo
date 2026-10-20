import CoreMedia
import Foundation

/// What the app found out about a candidate replacement file.
struct ReplacementAnalysis: Sendable {
    /// The candidate's own details, ready for `EditingProject.replaceMedia`.
    var replacement: MediaClip
    var snapshot: AssetMetadataSnapshot
    var audioEnvelope: AudioEnvelope?

    /// False when the original's reference data is missing, so nothing could
    /// be compared and the person has to judge the sync alone.
    var hasReference: Bool
    var report: MediaComparison.Report
    var suggestion: AlignmentSuggestion?
    var verdict: SyncVerdict
    /// The offset to use unless the person picks another.
    var proposedOffset: CMTime
    /// Parts of the project's used ranges that would fall outside the new
    /// file at `proposedOffset`.
    var missingRanges: [CMTimeRange]
    /// Used ranges in original time, kept so a manual offset can be checked.
    var usedRanges: [CMTimeRange]
    /// Set when the picture's cuts could have settled the sync but the
    /// original's scores aren't available (forgotten, or never set aside),
    /// so only sound was used. Nothing is made up in their place.
    var cutMatchingUnavailable: OriginalScoresUnavailable? = nil
    /// Whether the original's and the candidate's sound were both available
    /// and so compared. False when either has none.
    var audioWasCompared = false

    /// What to tell the person when the picture's cuts could not help, or
    /// nil when they were not needed. It claims a sound comparison only if
    /// one took place.
    var alignmentLimitation: String? {
        guard let reason = cutMatchingUnavailable else { return nil }
        return Self.limitation(reason, audioWasCompared: audioWasCompared)
    }

    static func limitation(_ reason: OriginalScoresUnavailable, audioWasCompared: Bool) -> String {
        audioWasCompared
            ? "\(reason.sentence) The sync was judged by sound alone; check the alignment yourself."
            : "\(reason.sentence) There was no sound to compare either, so the alignment could not be established. Set it by hand."
    }

    /// Whether the replacement can go ahead without the person being asked.
    var needsNoQuestions: Bool {
        hasReference && verdict == .aligned && report.isClean && missingRanges.isEmpty
    }

    func missingRanges(forOffset offset: CMTime) -> [CMTimeRange] {
        MediaComparison.missingRanges(used: usedRanges, offset: offset, newDuration: replacement.duration)
    }
}

/// Why a file can't replace an asset whatever is in it.
enum ReplacementKindError: LocalizedError {
    /// A still replaced by footage or sound, or the other way round.
    case stillAndFootage(originalIsStill: Bool)

    var errorDescription: String? {
        switch self {
        case .stillAndFootage(let originalIsStill):
            originalIsStill
                ? "A still can only be replaced by another picture."
                : "Footage and sound can't be replaced by a still."
        }
    }
}

enum MediaReplacer {
    /// One video frame at the project's frame rate, or a 24th of a second.
    static func tolerance(frameRate: Double) -> CMTime {
        let rate = frameRate > 0 ? frameRate : 24
        return CMTime(seconds: 1 / rate, preferredTimescale: 6000)
    }

    /// Reads the candidate file and compares it with what was saved about the
    /// original. `originalScores` are the original footage's change scores
    /// (never those of a replacement file), used to match cuts when audio
    /// can't decide; the offset found is from the original's time to the
    /// candidate's file, so it holds however many files came between. When
    /// they are `.failure`, the reason is reported in the result. A Matroska
    /// candidate's reference movie goes in `packageURL`'s cache.
    static func analyze(
        candidate url: URL,
        replacing asset: MediaClip,
        reference: AssetReference?,
        originalScores: Result<ChangeScoreTrack, OriginalScoresUnavailable>,
        usedRanges: [CMTimeRange],
        packageURL: URL?,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ReplacementAnalysis {
        let replacement = try await MediaImporter.importClip(at: url, packageURL: packageURL)
        if asset.kind == .image || replacement.kind == .image {
            guard asset.kind == replacement.kind else {
                throw ReplacementKindError.stillAndFootage(originalIsStill: asset.kind == .image)
            }
            progress(1)
            return stillReplacement(replacement, at: url)
        }
        let captured = try await ReferenceCapture.capture(url: url) { progress($0 * 0.5) }

        guard let reference else {
            return ReplacementAnalysis(
                replacement: replacement, snapshot: captured.metadata, audioEnvelope: captured.audioEnvelope,
                hasReference: false, report: MediaComparison.Report(),
                suggestion: nil, verdict: .needsConfirmation(suggestion: nil),
                proposedOffset: asset.alignmentOffset,
                missingRanges: MediaComparison.missingRanges(used: usedRanges, offset: asset.alignmentOffset, newDuration: replacement.duration),
                usedRanges: usedRanges
            )
        }

        var suggestion = MediaAlignment.suggest(
            referenceAudio: reference.audioEnvelope, candidateAudio: captured.audioEnvelope,
            referenceScores: nil, candidateScores: nil
        )
        // Scoring every frame of the new file is slow, so only do it when the
        // audio didn't settle the question.
        var cutMatchingUnavailable: OriginalScoresUnavailable?
        if suggestion?.isConfident != true, captured.metadata.isVideo {
            switch originalScores {
            case .failure(let reason):
                cutMatchingUnavailable = reason
            case .success(let originalScores):
                if let scores = try? await FrameScorer.score(url: url, progress: { progress(0.5 + $0 * 0.5) }) {
                    let fromCuts = MediaAlignment.suggest(
                        referenceAudio: nil, candidateAudio: nil,
                        referenceScores: originalScores, candidateScores: scores
                    )
                    if let fromCuts, fromCuts.confidence > (suggestion?.confidence ?? 0) { suggestion = fromCuts }
                }
            }
        }
        progress(1)

        let verdict = SyncVerdict.decide(
            suggestion: suggestion,
            currentOffset: asset.alignmentOffset,
            tolerance: tolerance(frameRate: asset.frameRate)
        )
        let proposed: CMTime
        switch verdict {
        case .aligned: proposed = asset.alignmentOffset
        case .needsConfirmation(let found): proposed = found?.offset ?? asset.alignmentOffset
        }

        var report = MediaComparison.compare(old: reference.metadata, new: captured.metadata)
        let missing = MediaComparison.missingRanges(used: usedRanges, offset: proposed, newDuration: replacement.duration)
        if !missing.isEmpty { report.blockers.append(.missingRanges(missing)) }

        return ReplacementAnalysis(
            replacement: replacement, snapshot: captured.metadata, audioEnvelope: captured.audioEnvelope,
            hasReference: true, report: report, suggestion: suggestion, verdict: verdict,
            proposedOffset: proposed, missingRanges: missing, usedRanges: usedRanges,
            cutMatchingUnavailable: cutMatchingUnavailable,
            audioWasCompared: reference.audioEnvelope != nil && captured.audioEnvelope != nil
        )
    }

    /// A picture replacing a still: it has no time to fall out of sync, so
    /// nothing is compared and it goes ahead without questions.
    private static func stillReplacement(_ replacement: MediaClip, at url: URL) -> ReplacementAnalysis {
        let stamp = FileStamp(url: url)
        let size = MediaImporter.stillSize(at: url) ?? .zero
        let snapshot = AssetMetadataSnapshot(
            fileName: url.lastPathComponent, originalPath: url.path, byteCount: stamp?.byteCount ?? 0, modified: stamp?.modified,
            isVideo: false, durationValue: replacement.duration.value, durationTimescale: replacement.duration.timescale,
            frameRate: 0, width: Int(size.width), height: Int(size.height), codecName: replacement.codecName,
            colorPrimaries: nil, colorTransfer: nil, colorMatrix: nil, audioSampleRate: nil,
            capturedAt: Date().timeIntervalSince1970
        )
        return ReplacementAnalysis(
            replacement: replacement, snapshot: snapshot, audioEnvelope: nil,
            hasReference: true, report: MediaComparison.Report(), suggestion: nil, verdict: .aligned,
            proposedOffset: .zero, missingRanges: [], usedRanges: []
        )
    }
}
