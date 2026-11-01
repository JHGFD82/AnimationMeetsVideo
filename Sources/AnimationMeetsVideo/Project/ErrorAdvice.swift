import AVFoundation
import Foundation

/// Says what went wrong, and what to do about it, for an error shown to
/// the person.
///
/// The app's own errors (`ProjectStoreError`, `CompositionError`, …) are
/// already worded for people and are passed through. What the system
/// throws is often not: a full disk can arrive as "The operation couldn't
/// be completed. (NSCocoaErrorDomain error 640.)". Those are sorted into
/// the few causes a person can act on, looking through underlying errors,
/// and each gets one sentence with a next step. Anything else keeps the
/// system's own description.
enum ErrorAdvice {
    enum Cause: Equatable {
        case noSpace
        case noPermission
        case readOnly
        case missing
        case unreachable
        case damaged
        case unsupportedFormat
        case outOfMemory

        var sentence: String {
            switch self {
            case .noSpace:
                "There isn't enough free space on the disk. Free some space, or choose a folder on another disk, and try again."
            case .noPermission:
                "The app isn't allowed to use this file or folder. Check its permissions with File > Get Info in the Finder, or choose another place."
            case .readOnly:
                "The disk is read-only, so nothing can be written to it. Choose a folder on another disk."
            case .missing:
                "The file or folder isn't there any more. It may have been moved, renamed or deleted."
            case .unreachable:
                "The disk it's on can't be reached. If it's a network or external disk, reconnect it and try again."
            case .damaged:
                "The file is damaged, or isn't in a form the app can read."
            case .unsupportedFormat:
                "The Mac can't read this kind of file. Movies need H.264, HEVC or ProRes video in a QuickTime, MPEG-4 or Matroska file."
            case .outOfMemory:
                "The Mac ran out of memory. Quit other apps and try again."
            }
        }
    }

    /// One sentence or two for `error`, to show as an alert's message.
    static func sentence(for error: Error) -> String {
        cause(of: error)?.sentence ?? error.localizedDescription
    }

    /// The cause a person can act on, if `error` or one under it has one.
    static func cause(of error: Error) -> Cause? {
        var current: NSError? = error as NSError
        // Underlying errors can nest; a few levels is all the system uses.
        for _ in 0..<4 {
            guard let nsError = current else { return nil }
            if let cause = directCause(of: nsError) { return cause }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    /// `error` and the ones under it, each with its domain and code, for
    /// the log: "The operation could not be completed" alone says nothing.
    static func chain(of error: Error) -> String {
        var parts: [String] = []
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let nsError = current else { break }
            parts.append("\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " <- ")
    }

    private static func directCause(of error: NSError) -> Cause? {
        switch error.domain {
        case NSCocoaErrorDomain:
            switch CocoaError.Code(rawValue: error.code) {
            case .fileWriteOutOfSpace: return .noSpace
            case .fileReadNoPermission, .fileWriteNoPermission: return .noPermission
            case .fileWriteVolumeReadOnly: return .readOnly
            case .fileNoSuchFile, .fileReadNoSuchFile: return .missing
            case .fileReadCorruptFile: return .damaged
            default: return nil
            }
        case NSPOSIXErrorDomain:
            switch POSIXErrorCode(rawValue: Int32(error.code)) {
            case .ENOSPC, .EDQUOT: return .noSpace
            case .EACCES, .EPERM: return .noPermission
            case .EROFS: return .readOnly
            case .ENOENT: return .missing
            case .ENETDOWN, .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH, .ETIMEDOUT, .ESTALE, .ENXIO: return .unreachable
            case .ENOMEM: return .outOfMemory
            default: return nil
            }
        case AVFoundationErrorDomain:
            switch AVError.Code(rawValue: error.code) {
            case .diskFull: return .noSpace
            case .outOfMemory: return .outOfMemory
            case .fileFormatNotRecognized, .decoderNotFound, .formatUnsupported: return .unsupportedFormat
            case .failedToParse: return .damaged
            case .noLongerPlayable: return .missing
            default: return nil
            }
        default:
            return nil
        }
    }
}
