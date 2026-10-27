import Foundation

/// How the sound of two clips crossfades under a transition joining them,
/// when the sound is still attached to their pictures. Its timing is the
/// transition's, as the picture's is; only the shape of the two fades is
/// its own. Detached sound takes the Audio transitions, each of which
/// fades with one of these (`TransitionKind.soundShape`).
///
/// A transition can choose one (`ClipTransition.audioCrossfade`); one that
/// doesn't follows the project's (`EditingProject.jointAudioCrossfade`),
/// an S-curve unless the project says otherwise.
enum AudioCrossfade: String, CaseIterable, Identifiable, Sendable {
    /// Each side eases out of and into its level: the gains are a raised
    /// cosine, summing to one, so the level dips a little at the middle
    /// but neither sound jumps at the ends.
    case sCurve
    /// Each side is down 3 dB at the middle, so two different sounds stay
    /// as loud through the crossfade as either alone.
    case equalPower
    /// The gains change at a steady rate, summing to one.
    case linear

    var id: Self { self }

    var name: String {
        switch self {
        case .sCurve: "S-Curve"
        case .equalPower: "Equal Power"
        case .linear: "Linear"
        }
    }

    var detail: String {
        switch self {
        case .sCurve: "Eases each sound out and in, with no jump at either end"
        case .equalPower: "Keeps two different sounds at an even loudness throughout"
        case .linear: "Changes each sound's level at a steady rate"
        }
    }

    /// The gain of the sound coming in after `progress` (0...1) of the
    /// crossfade; the sound going out has the gain at `1 - progress`.
    func gain(at progress: Double) -> Float {
        let p = progress.clamped(between: 0, and: 1)
        return switch self {
        case .sCurve: Float((1 - cos(p * .pi)) / 2)
        case .equalPower: Float(sin(p * .pi / 2))
        case .linear: Float(p)
        }
    }
}
