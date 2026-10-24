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
        return decibels.clamped(between: silence, and: maximum)
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

/// Where a clip's or layer's sound sits between the speakers, from −100
/// (left only) through 0 (as the media is) to +100 (right only). It is a
/// balance: moving toward one side turns the other channel down, and the
/// near one stays as it is, so the center is unchanged rather than 3 dB
/// down. Keyframes blend linearly.
enum AudioPan {
    static let range = -100.0...100.0

    static func clamped(_ pan: Double) -> Double {
        guard pan.isFinite else { return pan > 0 ? range.upperBound : range.lowerBound }
        return pan.clamped(between: range.lowerBound, and: range.upperBound)
    }

    /// The left and right channels' gain factors.
    static func gains(_ pan: Double) -> SIMD2<Float> {
        let p = Float(clamped(pan) / 100)
        return SIMD2(min(1, 1 - p), min(1, 1 + p))
    }

    /// "C", "L 30" or "R 100".
    static func label(_ pan: Double) -> String {
        let number = NumericExpression.format(abs(clamped(pan)), maxFractionDigits: 0)
        if number == "0" { return "C" }
        return (pan < 0 ? "L " : "R ") + number
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

    /// Applies `change` to a layer's pan, as `editVolume` does its volume.
    mutating func editPan(of layerID: UUID, in timelineID: UUID, _ change: (inout AnimatedValue<Double>) -> Void) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        change(&timelines[tIndex].layers[lIndex].pan)
    }

    /// Whether any clip on the layer makes sound, so its volume matters.
    func layerPlaysAudio(_ layer: TimelineLayer) -> Bool {
        layer.clips.contains { playsAudio($0) }
    }
}
