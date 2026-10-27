import Foundation

/// The size the viewer draws the timeline at, chosen by the person.
enum PreviewQuality: String, CaseIterable, Identifiable {
    /// Full size when paused; while playing, as large as keeps up.
    case auto
    case full, half, quarter

    var id: Self { self }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .full: "Full"
        case .half: "Half"
        case .quarter: "Quarter"
        }
    }

    /// The level a fixed setting always draws at; nil for Auto.
    var fixedLevel: PreviewLevel? {
        switch self {
        case .auto: nil
        case .full: .full
        case .half: .half
        case .quarter: .quarter
        }
    }
}

/// A size the viewer can draw at, as a fraction of the timeline's frame
/// in each direction. Each step down draws a quarter of the pixels.
enum PreviewLevel: Int, Comparable {
    case full, half, quarter

    var scale: Double {
        switch self {
        case .full: 1
        case .half: 0.5
        case .quarter: 0.25
        }
    }

    var label: String {
        switch self {
        case .full: "Full"
        case .half: "½"
        case .quarter: "¼"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var smaller: Self? { Self(rawValue: rawValue + 1) }
    var larger: Self? { Self(rawValue: rawValue - 1) }
}

/// Chooses the level for Auto while playing. Playback that falls behind
/// steps down a level at once; stepping back up waits until rendering has
/// clearly had room for a while, and then until the next pause, since
/// changing size swaps the composition and freezes the picture for a
/// moment. Stepping down already follows a stutter, so it can't wait. The level stays put while paused, so pressing play never swaps
/// the player's composition (which would throw away what it buffered);
/// the viewer covers paused frames with a full-size still instead.
struct PreviewGovernor {
    struct Sample {
        /// Seconds on any steady clock.
        var time: Double
        var framesPerSecond: Double
        /// Average time to draw one frame at the current level.
        var renderSeconds: Double
    }

    private(set) var level: PreviewLevel = .full
    /// A larger level playback has earned, taken at the next pause.
    private(set) var stepUpOnPause: PreviewLevel?
    private var isPlaying = false
    private var lastChange = -Double.infinity
    private var behindSamples = 0

    /// Samples this soon after playing starts or the level changes are
    /// ignored, since the player fills its buffer in a burst then.
    static let settleSeconds = 0.75
    /// How long playback has to keep up before trying a larger level.
    static let stepUpAfterSeconds = 5.0

    mutating func startPlaying(at time: Double) {
        isPlaying = true
        lastChange = time
        behindSamples = 0
    }

    mutating func stopPlaying() {
        isPlaying = false
        if let stepUpOnPause { level = stepUpOnPause }
        stepUpOnPause = nil
    }

    /// Takes a measurement of playback and returns whether the level changed
    /// now.
    mutating func record(_ sample: Sample, frameRate: Double) -> Bool {
        guard isPlaying, frameRate > 0, sample.time - lastChange >= Self.settleSeconds else { return false }

        if sample.framesPerSecond < frameRate * 0.9 {
            behindSamples += 1
            // Two in a row, so one hiccup (a disk stall, a seek) doesn't count.
            guard behindSamples >= 2, let smaller = level.smaller else { return false }
            change(to: smaller, at: sample.time)
            return true
        }
        behindSamples = 0

        // A level up draws four times the pixels. Decoding costs the same at
        // every level, and playback is keeping up, so only drawing matters.
        let frameSeconds = 1 / frameRate
        guard stepUpOnPause == nil, let larger = level.larger,
              sample.time - lastChange >= Self.stepUpAfterSeconds,
              sample.framesPerSecond >= frameRate * 0.97,
              sample.renderSeconds * 4 < frameSeconds * 0.4
        else {
            return false
        }
        stepUpOnPause = larger
        return false
    }

    private mutating func change(to newLevel: PreviewLevel, at time: Double) {
        level = newLevel
        stepUpOnPause = nil
        lastChange = time
        behindSamples = 0
    }
}
