import CoreMedia
import Foundation

/// Compares a replacement file with the saved snapshot of the original and
/// sorts the differences into the tiers described in docs/media-replacement.md.
enum MediaComparison {
    /// Aspect ratios closer than this (relative) count as the same.
    static let aspectTolerance = 0.01

    enum Confirmation: Equatable, Sendable {
        case aspectRatio(old: Double, new: Double)
        /// One of the two files is HDR and the other isn't.
        case dynamicRange(oldIsHDR: Bool, newIsHDR: Bool)
        /// The new file's color tags are missing or incomplete, so the app can
        /// only guess how to show it.
        case untaggedColor
    }

    enum Blocker: Equatable, Sendable {
        /// The new file lacks something the old one had that the project may use.
        case lostVideo
        case lostAudio
        /// Parts of the project's used ranges fall outside the new file.
        case missingRanges([CMTimeRange])
    }

    struct Report: Equatable, Sendable {
        /// Differences handled without asking, worded for display.
        var adjustments: [String] = []
        var confirmations: [Confirmation] = []
        var blockers: [Blocker] = []

        var isClean: Bool { confirmations.isEmpty && blockers.isEmpty }
    }

    static func compare(old: AssetMetadataSnapshot, new: AssetMetadataSnapshot) -> Report {
        var report = Report()

        if old.isVideo && !new.isVideo { report.blockers.append(.lostVideo) }
        if old.hasAudio && !new.hasAudio { report.blockers.append(.lostAudio) }

        if old.isVideo && new.isVideo {
            if old.width != new.width || old.height != new.height {
                report.adjustments.append("Size changes from \(old.width)×\(old.height) to \(new.width)×\(new.height); it is scaled to fill the same frame.")
            }
            if let oldRatio = aspectRatio(old), let newRatio = aspectRatio(new),
               abs(newRatio - oldRatio) / oldRatio > aspectTolerance {
                report.confirmations.append(.aspectRatio(old: oldRatio, new: newRatio))
            }
            if abs(old.frameRate - new.frameRate) > 0.01, old.frameRate > 0, new.frameRate > 0 {
                report.adjustments.append("Frame rate changes from \(format(old.frameRate)) to \(format(new.frameRate)) fps; frames are matched by time.")
            }

            let oldHDR = isHDR(old), newHDR = isHDR(new)
            if oldHDR != newHDR {
                report.confirmations.append(.dynamicRange(oldIsHDR: oldHDR, newIsHDR: newHDR))
            }
            if !new.hasColorTags {
                report.confirmations.append(.untaggedColor)
            }
        }
        return report
    }

    static func aspectRatio(_ metadata: AssetMetadataSnapshot) -> Double? {
        guard metadata.width > 0, metadata.height > 0 else { return nil }
        return Double(metadata.width) / Double(metadata.height)
    }

    /// PQ and HLG transfer functions mean HDR.
    static func isHDR(_ metadata: AssetMetadataSnapshot) -> Bool {
        guard let transfer = metadata.colorTransfer else { return false }
        return transfer.contains("2084") || transfer.contains("HLG") || transfer.contains("2100")
    }

    private static func format(_ rate: Double) -> String {
        let text = String(format: "%.3f", rate)
        return text.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    /// The parts of `used` (in original time) that don't fit inside a new file
    /// of `newDuration` once shifted by `offset`. Empty when everything fits.
    static func missingRanges(used: [CMTimeRange], offset: CMTime, newDuration: CMTime) -> [CMTimeRange] {
        // Allow a rounding slop of a millisecond.
        let slop = CMTime(value: 1, timescale: 1000)
        var missing: [CMTimeRange] = []
        for range in used where range.duration > .zero {
            let shifted = CMTimeRange(start: CMTimeAdd(range.start, offset), duration: range.duration)
            let end = shifted.end
            if CMTimeCompare(shifted.start, CMTimeMultiply(slop, multiplier: -1)) < 0 {
                let cutEnd = CMTimeMinimum(end, .zero)
                missing.append(CMTimeRange(start: range.start, end: CMTimeSubtract(cutEnd, offset)))
            }
            if CMTimeCompare(end, CMTimeAdd(newDuration, slop)) > 0 {
                let cutStart = CMTimeMaximum(shifted.start, newDuration)
                missing.append(CMTimeRange(start: CMTimeSubtract(cutStart, offset), end: range.end))
            }
        }
        return missing
    }
}

/// What the sync dialog should do for a replacement.
enum SyncVerdict: Equatable, Sendable {
    /// The files line up at the offset already in effect; nothing to ask.
    case aligned
    /// Open the sync dialog. `suggestion` is prefilled when one was found.
    case needsConfirmation(suggestion: AlignmentSuggestion?)

    /// Decides whether a replacement is obviously in sync.
    ///
    /// Aligned means a confident suggestion that agrees with the offset
    /// already in effect (within `tolerance`). A confident suggestion that
    /// disagrees, a weak one, or none at all sends the person to the dialog.
    static func decide(
        suggestion: AlignmentSuggestion?,
        currentOffset: CMTime,
        tolerance: CMTime
    ) -> SyncVerdict {
        guard let suggestion, suggestion.isConfident else {
            return .needsConfirmation(suggestion: suggestion)
        }
        let difference = CMTimeAbsoluteValue(CMTimeSubtract(suggestion.offset, currentOffset))
        return CMTimeCompare(difference, tolerance) <= 0
            ? .aligned
            : .needsConfirmation(suggestion: suggestion)
    }
}
