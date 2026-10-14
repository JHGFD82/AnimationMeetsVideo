import CoreMedia
import Foundation

/// A layer's volume, in decibels relative to its media: 0 plays it as it
/// is, up to `maximum` (+6, twice as loud in amplitude), and down to
/// `silence`, which mutes it. Keyframes blend in decibels, so a fade sounds
/// even rather than dropping away at the end.
enum AudioLevel {
    static let maximum = 6.0
    /// At or below this the layer is muted. Shown as −∞.
    static let silence = -60.0
    static let range = silence...maximum

    static func clamped(_ decibels: Double) -> Double {
        guard decibels.isFinite else { return decibels > 0 ? maximum : silence }
        return min(max(decibels, silence), maximum)
    }

    /// The amplitude factor for a level: 1 at 0 dB, 0 when muted.
    static func gain(decibels: Double) -> Float {
        let level = clamped(decibels)
        guard level > silence else { return 0 }
        return Float(pow(10, level / 20))
    }

    /// "0 dB", "+3.5 dB", "−12 dB" or "−∞ dB".
    static func label(_ decibels: Double) -> String {
        let level = clamped(decibels)
        if level <= silence { return "−∞ dB" }
        let number = NumericExpression.format(abs(level), maxFractionDigits: 1)
        if number == "0" { return "0 dB" }
        return (level > 0 ? "+" : "−") + number + " dB"
    }
}

extension TimelineLayer {
    /// The layer's volume at `time` in its timeline, as a gain factor.
    func gain(at time: CMTime) -> Float {
        AudioLevel.gain(decibels: volume.value(at: time))
    }
}

extension EditingProject {
    /// Applies `change` to a layer's volume (decibels). Times passed in
    /// should already be snapped to the timeline's frames.
    mutating func editVolume(of layerID: UUID, in timelineID: UUID, _ change: (inout AnimatedValue<Double>) -> Void) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        change(&timelines[tIndex].layers[lIndex].volume)
    }

    /// Whether any clip on the layer makes sound, so its volume matters.
    func layerPlaysAudio(_ layer: TimelineLayer) -> Bool {
        layer.clips.contains { playsAudio($0) }
    }
}
