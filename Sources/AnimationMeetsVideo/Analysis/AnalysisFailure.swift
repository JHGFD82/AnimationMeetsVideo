import AVFoundation
import Foundation

/// Why one stage of an asset's analysis did not produce a result, with the
/// file it was run on, so it can be told from a failure on an earlier file
/// and dropped when the file changes.
struct AnalysisFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The file is gone (a drive unplugged, a file moved).
        case missingFile
        /// The file is there but may not be read.
        case permissionDenied
        /// The file has no track of the kind needed, or a format or codec
        /// that can't be decoded.
        case unsupportedMedia
        /// The file is damaged or can't be parsed.
        case corruptMedia
        /// The result was made but could not be written into the project.
        case persistence
        /// The project's saved results could not be read. Recorded under
        /// the scene stage, though it holds for all of the asset's results.
        case unreadableProject
        /// The work stopped without being asked to.
        case interrupted
        case other

        var explanation: String {
            switch self {
            case .missingFile: "The file is missing."
            case .permissionDenied: "The file can't be read: permission was denied."
            case .unsupportedMedia: "The file's format isn't supported for this."
            case .corruptMedia: "The file looks damaged."
            case .persistence: "The result couldn't be saved into the project."
            case .unreadableProject: "The results saved in the project couldn't be read."
            case .interrupted: "The analysis was interrupted."
            case .other: "The analysis failed."
            }
        }
    }

    var stage: AssetAnalysis.Stage
    var kind: Kind
    /// The error's own description.
    var message: String
    /// The file the stage ran on: the revision of the source it failed for.
    var file: AssetAnalysis.AnalyzedFile?

    var title: String {
        switch (stage, kind) {
        case (_, .persistence): "Couldn't save results"
        case (_, .unreadableProject): "Couldn't read saved results"
        case (.reference, _): "Reading the original failed"
        case (.scenes, _): "Scene detection failed"
        case (.pictures, _): "Saving pictures failed"
        case (.beats, _): "Beat detection failed"
        }
    }

    /// For a tooltip: what kind of problem it was, then what the system said.
    var detail: String {
        message.isEmpty || message == kind.explanation ? kind.explanation : "\(kind.explanation) \(message)"
    }

    init(stage: AssetAnalysis.Stage, error: any Error, file: AssetAnalysis.AnalyzedFile?, kind: Kind? = nil) {
        self.stage = stage
        self.kind = kind ?? Self.kind(of: error)
        self.message = kind == .interrupted ? "" : error.localizedDescription
        self.file = file
    }

    static func kind(of error: any Error) -> Kind {
        if error is CancellationError { return .interrupted }
        switch error {
        case FrameScorer.ScoringError.noVideoTrack, BeatDetector.DetectionError.noAudioTrack, MediaImportError.noTracks:
            return .unsupportedMedia
        case FrameScorer.ScoringError.readerFailed(let reason, let underlying),
             BeatDetector.DetectionError.readerFailed(let reason, let underlying):
            if let underlying { return kind(of: underlying) }
            return reason.contains("unsupported") ? .unsupportedMedia : .other
        case is ChangeScoreTrackError, is BeatTracker.InputError:
            // The onset curve comes from the decoded audio, so values that
            // aren't numbers mean the audio held some.
            return .corruptMedia
        default:
            break
        }
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError), (NSCocoaErrorDomain, NSFileReadNoSuchFileError),
             (NSPOSIXErrorDomain, Int(ENOENT)):
            return .missingFile
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError), (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
             (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)):
            return .permissionDenied
        case (NSCocoaErrorDomain, NSFileReadCorruptFileError):
            return .corruptMedia
        case (AVFoundationErrorDomain, AVError.fileFormatNotRecognized.rawValue),
             (AVFoundationErrorDomain, AVError.decoderNotFound.rawValue),
             (AVFoundationErrorDomain, AVError.formatUnsupported.rawValue):
            return .unsupportedMedia
        case (AVFoundationErrorDomain, AVError.fileFailedToParse.rawValue),
             (AVFoundationErrorDomain, AVError.failedToParse.rawValue):
            return .corruptMedia
        case (AVFoundationErrorDomain, AVError.contentIsNotAuthorized.rawValue),
             (AVFoundationErrorDomain, AVError.applicationIsNotAuthorized.rawValue):
            return .permissionDenied
        default:
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error { return kind(of: underlying) }
            return .other
        }
    }
}
