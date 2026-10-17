import CryptoKit
import Foundation

/// The results that describe the file an asset uses now, as opposed to the
/// reference data, which describes the original and survives replacement.
enum AnalysisKind: String, Codable, CaseIterable, Sendable {
    /// Scores of the file the asset uses now.
    case scores
    case beats
    /// Scores of the original footage: reference data, kept through
    /// replacement so a later file can be aligned to the original. Their
    /// record names the original file, not the current one.
    case originalScores
}

/// The file identity each saved result was computed from, by asset.
struct AnalysisSources: Equatable, Sendable {
    var scores: [UUID: FileStamp] = [:]
    var beats: [UUID: FileStamp] = [:]
    var originalScores: [UUID: FileStamp] = [:]
}

/// Why an asset has no original scores to align a replacement with.
enum OriginalScoresUnavailable: Error, Equatable, Sendable {
    /// The person chose Forget Original, which deletes them.
    case forgotten
    /// They were never captured while the original was the asset's file
    /// (or were saved by a version that did not keep them separately), and
    /// the scores of the current file are not the original's.
    case notCaptured
    /// Saved, but the file is damaged.
    case damaged
    /// Saved with settings this version can't use.
    case incompatible
    /// Saved, but not shown to come from the original (no usable record, or
    /// a record naming another file than the saved reference does).
    case unverified

    var sentence: String {
        switch self {
        case .forgotten: "The original was forgotten, so its cuts can't be matched."
        case .notCaptured: "The original's cuts weren't saved, so they can't be matched."
        case .damaged: "The original's saved cuts are damaged, so they can't be matched."
        case .incompatible: "The original's saved cuts were made in a way this version can't use, so they can't be matched."
        case .unverified: "The original's saved cuts can't be shown to be the original's, so they aren't used."
        }
    }
}

extension AnalysisRejection {
    /// How a rejected original-scores file is told apart from a missing one.
    var originalScoresReason: OriginalScoresUnavailable {
        switch self {
        case .damaged: .damaged
        case .differentSettings, .differentAlgorithm: .incompatible
        case .noProvenance, .invalidated, .differentFile, .unverifiable: .unverified
        }
    }
}

/// What a saved score or beat file was computed from, saved beside it in
/// `provenance.json`. A result is used only when all of it still applies;
/// a result with no record, as from before this existed, is analyzed again
/// rather than assumed to belong to the file the asset has now.
struct AnalysisProvenance: Codable, Equatable, Sendable {
    /// The file's size and modification time when it was analyzed. Nil when
    /// the file couldn't be stamped, which makes the result unverifiable.
    var source: FileStamp?
    /// The parameters the analysis ran with, so changing one retires results
    /// made with the old value.
    var settings: String
    /// Bumped by hand when a change to the algorithm makes old results wrong
    /// while the settings and file format stay the same.
    var algorithm: Int
    /// SHA-256 of the result file, so a result file and a record that came
    /// from different writes are never taken for a pair.
    var digest: String
    /// Set when the result was retired but its file couldn't be deleted.
    var invalidated: Bool = false

    static func current(for kind: AnalysisKind) -> (settings: String, algorithm: Int) {
        switch kind {
        case .scores, .originalScores:
            // 2: footage in an empty edit is no longer scored as a frame, so
            // a late-start file no longer reads as cut at its first picture.
            return ("sample=\(FrameScorer.sampleWidth)x\(FrameScorer.sampleHeight)", 2)
        case .beats:
            let settings = [
                "rate=\(BeatDetector.sampleRate)", "window=\(OnsetAnalyzer.windowSize)", "hop=\(OnsetAnalyzer.hopSize)",
                "bpm=\(BeatTracker.minimumBPM)-\(BeatTracker.maximumBPM)", "preferred=\(BeatTracker.preferredBPM)",
                "tightness=\(BeatTracker.tightness)", "minimum=\(BeatTracker.minimumSeconds)",
                "tempoWindow=\(BeatTracker.tempoWindowSeconds)", "tempoHop=\(BeatTracker.tempoHopSeconds)",
                "glide=\(BeatTracker.tempoGlide)", "jump=\(BeatTracker.tempoJump)", "sudden=\(BeatTracker.suddenChange)",
            ]
            // 2: the FFT's packed DC and Nyquist values no longer count
            // toward onsets. 3: the tempo is the beats' median gap.
            return (settings.joined(separator: ";"), 3)
        }
    }

    /// Whether a record made with `algorithm` can still be used. Current-file
    /// results must have been made by the current algorithm, so they are
    /// made again. The original's scores can't be: the original may be gone,
    /// and they are never made from a replacement. Those made by the
    /// algorithm before keep working for aligning a replacement; the one
    /// difference, a spurious cut at the first picture of a file that started
    /// late, is one cut among the several that matching needs.
    static func accepts(algorithm: Int, for kind: AnalysisKind) -> Bool {
        let current = Self.current(for: kind).algorithm
        return kind == .originalScores ? (1...current).contains(algorithm) : algorithm == current
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Why a saved result was not used.
enum AnalysisRejection: Equatable, Sendable {
    /// No record of what it was computed from (saved by an older version).
    case noProvenance
    /// Retired, but its file couldn't be deleted at the time.
    case invalidated
    /// Computed from a different file than the asset has now.
    case differentFile
    /// Either side's file identity is unknown, so they can't be compared.
    case unverifiable
    case differentSettings
    case differentAlgorithm
    /// The file doesn't match its record or can't be decoded.
    case damaged

    var sentence: String {
        switch self {
        case .noProvenance: "It has no record of the file it came from."
        case .invalidated: "It was retired."
        case .differentFile: "It came from a different file."
        case .unverifiable: "The file's identity couldn't be checked."
        case .differentSettings: "It was made with different settings."
        case .differentAlgorithm: "It was made by an older version of the analysis."
        case .damaged: "It is damaged."
        }
    }
}

enum CachedResult<Value> {
    case absent
    case valid(Value, source: FileStamp)
    case rejected(AnalysisRejection)

    var value: Value? {
        if case .valid(let value, _) = self { return value }
        return nil
    }
}

extension CachedResult: Sendable where Value: Sendable {}
