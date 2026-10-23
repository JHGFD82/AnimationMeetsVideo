import CoreMedia
import Foundation

// The choices of the looks still written in Swift, Displace and Slit-Scan
// (see docs/psychedelic-effects.md); the others' are in their packages.

/// Which of a Displace map's values leaves a pixel where it is.
enum MapCenter: String, CaseIterable, Identifiable, Sendable {
    /// Middle gray: darker moves one way, lighter the other.
    case gray
    /// Black: the map only ever pushes one way.
    case black

    var id: Self { self }

    var name: String {
        switch self {
        case .gray: "Gray"
        case .black: "Black"
        }
    }
}

/// Which way Slit-Scan's bands run: each from a moment later than the last.
enum SlitDirection: String, CaseIterable, Identifiable, Sendable {
    /// Across, the top now.
    case rows
    /// Down, the left now.
    case columns
    /// Round the center, the middle now.
    case rings

    var id: Self { self }

    var name: String {
        switch self {
        case .rows: "Rows"
        case .columns: "Columns"
        case .rings: "Rings"
        }
    }
}

/// How long before the moment drawn each copy Feedback and Slit-Scan draw
/// from is, on the timeline's frames, so the composition and the
/// compositor agree on them, and copies can be shared.
enum MomentDelays {
    static func feedback(copy: Int, delayFrames: Int, frame: CMTime) -> CMTime {
        CMTimeMultiply(frame, multiplier: Int32(copy * max(delayFrames, 1)))
    }

    /// Band `band` of `bands` (0 is now) is `spread` seconds across the
    /// last, rounded to a frame.
    static func slit(band: Int, of bands: Int, spread: Double, frame: CMTime) -> CMTime {
        guard bands > 1, frame.seconds > 0 else { return .zero }
        let seconds = Double(band) / Double(bands - 1) * spread
        return CMTimeMultiply(frame, multiplier: Int32((seconds / frame.seconds).rounded()))
    }
}
