import CryptoKit
import Foundation

/// The results that describe the file an asset uses now, as opposed to the
/// reference data, which describes the original and survives replacement.
enum AnalysisKind: String, Codable, CaseIterable, Sendable {
    case scores, beats
}

/// The file identity each saved result was computed from, by asset.
struct AnalysisSources: Equatable, Sendable {
    var scores: [UUID: FileStamp] = [:]
    var beats: [UUID: FileStamp] = [:]
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
        case .scores:
            return ("sample=\(FrameScorer.sampleWidth)x\(FrameScorer.sampleHeight)", 1)
        case .beats:
            let settings = [
                "rate=\(BeatDetector.sampleRate)", "window=\(OnsetAnalyzer.windowSize)", "hop=\(OnsetAnalyzer.hopSize)",
                "bpm=\(BeatTracker.minimumBPM)-\(BeatTracker.maximumBPM)", "preferred=\(BeatTracker.preferredBPM)",
                "tightness=\(BeatTracker.tightness)", "minimum=\(BeatTracker.minimumSeconds)",
                "tempoWindow=\(BeatTracker.tempoWindowSeconds)", "tempoHop=\(BeatTracker.tempoHopSeconds)",
                "glide=\(BeatTracker.tempoGlide)", "jump=\(BeatTracker.tempoJump)", "sudden=\(BeatTracker.suddenChange)",
            ]
            return (settings.joined(separator: ";"), 1)
        }
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
