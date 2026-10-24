import CoreMedia
import Foundation

extension CMTime {
    var formatted: String {
        guard isNumeric else { return "--:--" }
        let totalSeconds = max(0, seconds)
        let tenths = Int((totalSeconds * 10).rounded())
        return String(format: "%02ld:%02ld.%ld", (tenths / 10) / 60, (tenths / 10) % 60, tenths % 10)
    }

    /// hh:mm:ss:ff timecode using the given frame rate for the frames field.
    /// It counts frames non-drop-frame, at the rate rounded to whole frames,
    /// so at 29.97 fps it runs about 3.6 s behind the clock per hour.
    func timecode(frameRate: Double) -> String {
        guard isNumeric, frameRate > 0 else { return "00:00:00:00" }
        let totalSeconds = max(0, seconds)
        let framesPerSecond = max(1, Int(frameRate.rounded()))
        let totalFrames = Int((totalSeconds * frameRate).rounded())
        let frames = totalFrames % framesPerSecond
        let totalWholeSeconds = totalFrames / framesPerSecond
        let secs = totalWholeSeconds % 60
        let mins = (totalWholeSeconds / 60) % 60
        let hours = totalWholeSeconds / 3600
        return String(format: "%02d:%02d:%02d:%02d", hours, mins, secs, frames)
    }

    /// The same timecode with leading zero-valued fields dropped (always
    /// keeping at least seconds:frames) and the leftmost remaining field's
    /// own leading zero stripped — "00:00:05:00" -> "5:00",
    /// "00:12:05:00" -> "12:05:00".
    func compactTimecode(frameRate: Double) -> String {
        let parts = timecode(frameRate: frameRate).split(separator: ":").map(String.init)
        var startIndex = 0
        while startIndex < parts.count - 2 && parts[startIndex] == "00" {
            startIndex += 1
        }
        var kept = Array(parts[startIndex...])
        if let first = kept.first {
            kept[0] = String(Int(first) ?? 0)
        }
        return kept.joined(separator: ":")
    }
}
