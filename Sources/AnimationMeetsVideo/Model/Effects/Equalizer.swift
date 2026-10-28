import CoreMedia
import Foundation

/// The shape of an EQ band's filter.
enum EqualizerShape: Sendable {
    case lowCut, lowShelf, bell, highShelf, highCut
}

/// How steeply a cut band falls away past its frequency.
enum EqualizerSlope: String, CaseIterable, Identifiable, Sendable {
    case db6 = "6", db12 = "12", db24 = "24", db48 = "48"

    var id: Self { self }

    var name: String { "\(rawValue) dB/oct" }

    /// How many second-order sections make it; 6 dB is one first-order one.
    var sectionCount: Int {
        switch self {
        case .db6, .db12: 1
        case .db24: 2
        case .db48: 4
        }
    }
}

/// One of the EQ's eight bands (see docs/equalizer.md), each a control of
/// the effect: a cut's components are its frequency and Q, a shelf's or a
/// bell's its frequency, gain and Q. A band is on while its control is.
enum EqualizerBand: Int, CaseIterable, Identifiable, Sendable {
    case lowCut, lowShelf, bell1, bell2, bell3, bell4, highShelf, highCut

    var id: Self { self }

    init?(controlKind: ControlKind) {
        guard let band = controlKind.equalizerBand else { return nil }
        self = band
    }

    var controlKind: ControlKind {
        switch self {
        case .lowCut: .eqLowCut
        case .lowShelf: .eqLowShelf
        case .bell1: .eqBell1
        case .bell2: .eqBell2
        case .bell3: .eqBell3
        case .bell4: .eqBell4
        case .highShelf: .eqHighShelf
        case .highCut: .eqHighCut
        }
    }

    /// The choice that sets a cut's slope.
    var slopeKind: ControlKind? {
        switch self {
        case .lowCut: .eqLowCutSlope
        case .highCut: .eqHighCutSlope
        default: nil
        }
    }

    var shape: EqualizerShape {
        switch self {
        case .lowCut: .lowCut
        case .lowShelf: .lowShelf
        case .bell1, .bell2, .bell3, .bell4: .bell
        case .highShelf: .highShelf
        case .highCut: .highCut
        }
    }

    var name: String {
        switch self {
        case .lowCut: "Low Cut"
        case .lowShelf: "Low Shelf"
        case .bell1: "Bell 1"
        case .bell2: "Bell 2"
        case .bell3: "Bell 3"
        case .bell4: "Bell 4"
        case .highShelf: "High Shelf"
        case .highCut: "High Cut"
        }
    }

    /// Whether it boosts or cuts by a gain; a cut has none.
    var hasGain: Bool { shape != .lowCut && shape != .highCut }

    static let frequencyIndex = 0
    /// Where its gain is among its components, if it has one.
    var gainIndex: Int? { hasGain ? 1 : nil }
    var qIndex: Int { hasGain ? 2 : 1 }

    /// A Q of 1/√2: a Butterworth cut, and shelves without a bump.
    static let flatQ = 0.7071

    var defaultFrequency: Double {
        switch self {
        case .lowCut: 30
        case .lowShelf: 100
        case .bell1: 250
        case .bell2: 800
        case .bell3: 2500
        case .bell4: 6000
        case .highShelf: 10_000
        case .highCut: 18_000
        }
    }

    var defaultQ: Double { shape == .bell ? 1 : Self.flatQ }

    var defaultValues: [Double] {
        hasGain ? [defaultFrequency, 0, defaultQ] : [defaultFrequency, defaultQ]
    }

    var componentNames: [String] {
        hasGain ? ["Frequency", "Gain", "Q"] : ["Frequency", "Q"]
    }

    func unit(ofComponent index: Int) -> String {
        switch index {
        case Self.frequencyIndex: " Hz"
        case gainIndex: " dB"
        default: ""
        }
    }

    func range(ofComponent index: Int) -> ClosedRange<Double> {
        switch index {
        case Self.frequencyIndex: Equalizer.frequencies
        case gainIndex: Equalizer.gains
        default: Equalizer.qs
        }
    }

    func dragStep(ofComponent index: Int) -> Double {
        switch index {
        case Self.frequencyIndex: 10
        case gainIndex: 0.1
        default: 0.01
        }
    }
}

/// The EQ sound effect's bands, read from its controls and turned into
/// filters. The tap (`EqualizerFilter`) and the graph draw from the same
/// coefficients, so the curve shown is the one heard.
enum Equalizer {
    static let frequencies = 20.0...20_000
    static let gains = -24.0...24
    static let qs = 0.1...18.0

    /// The effect's controls, in order down the panel.
    static let controlKinds: [ControlKind] = [
        .eqLowCut, .eqLowCutSlope, .eqLowShelf, .eqBell1, .eqBell2, .eqBell3, .eqBell4,
        .eqHighShelf, .eqHighCut, .eqHighCutSlope, .eqOutput,
    ]

    /// One band as it is set at a moment.
    struct BandSetting: Equatable, Sendable {
        var band: EqualizerBand
        var frequency: Double
        var gain: Double
        var q: Double
        var slope: EqualizerSlope = .db12
    }

    /// The bands that are on, and the output gain, at a moment.
    struct Settings: Equatable, Sendable {
        var bands: [BandSetting] = []
        /// In decibels.
        var output: Double = 0

        /// Changes nothing to the sound: no cuts, and every shelf and bell
        /// at 0 dB.
        var isFlat: Bool { output == 0 && bands.allSatisfy { $0.band.hasGain && $0.gain == 0 } }

        /// Part of the way from `self` to `other`: frequencies and Qs on a
        /// log scale, gains in decibels, so a sweep sounds even. With
        /// different bands on, or a different slope, it is `other`.
        func interpolated(to other: Settings, fraction: Double) -> Settings {
            guard fraction > 0 else { return self }
            guard fraction < 1, bands.count == other.bands.count,
                  zip(bands, other.bands).allSatisfy({ $0.band == $1.band && $0.slope == $1.slope })
            else { return other }
            func geometric(_ a: Double, _ b: Double) -> Double { a * pow(b / a, fraction) }
            func linear(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
            return Settings(
                bands: zip(bands, other.bands).map { a, b in
                    BandSetting(
                        band: a.band, frequency: geometric(a.frequency, b.frequency),
                        gain: linear(a.gain, b.gain), q: geometric(a.q, b.q), slope: a.slope
                    )
                },
                output: linear(output, other.output)
            )
        }
    }

    /// What `effect`'s controls set at `time`, in the clip's source time.
    /// Bands that are off or deleted are left out. A shelf or bell at 0 dB
    /// stays in: it passes sound unchanged, and keeping it means sweeping
    /// a gain through 0 doesn't change which filters run.
    static func settings(of effect: Effect, at time: CMTime) -> Settings {
        var settings = Settings()
        for control in effect.controls where control.enabled {
            if control.kind == .eqOutput {
                settings.output = ControlKind.eqOutput.clamped(control.values(at: time).first ?? 0)
                continue
            }
            guard let band = EqualizerBand(controlKind: control.kind) else { continue }
            let values = control.values(at: time)
            func value(_ index: Int) -> Double {
                band.range(ofComponent: index).clamp(values.indices.contains(index) ? values[index] : band.defaultValues[index])
            }
            let gain = band.gainIndex.map(value) ?? 0
            var setting = BandSetting(band: band, frequency: value(EqualizerBand.frequencyIndex), gain: gain, q: value(band.qIndex))
            if let slopeKind = band.slopeKind, let slope = effect.control(slopeKind), slope.enabled {
                setting.slope = slope.choice.flatMap(EqualizerSlope.init(rawValue:)) ?? .db12
            }
            settings.bands.append(setting)
        }
        settings.bands.sort { $0.band.rawValue < $1.band.rawValue }
        return settings
    }

    // MARK: Filters

    /// Appends the filter sections `setting` needs at `sampleRate` to
    /// `sections`. A cut steeper than 12 dB per octave is a Butterworth
    /// cascade whose last section takes the band's Q as resonance.
    static func appendSections(for setting: BandSetting, sampleRate: Double, to sections: inout [Biquad]) {
        let f = setting.frequency, q = setting.q
        switch setting.band.shape {
        case .lowShelf: sections.append(.lowShelf(frequency: f, gain: setting.gain, q: q, sampleRate: sampleRate))
        case .highShelf: sections.append(.highShelf(frequency: f, gain: setting.gain, q: q, sampleRate: sampleRate))
        case .bell: sections.append(.bell(frequency: f, gain: setting.gain, q: q, sampleRate: sampleRate))
        case .lowCut, .highCut:
            let high = setting.band.shape == .lowCut
            if setting.slope == .db6 {
                sections.append(.firstOrder(highPass: high, frequency: f, sampleRate: sampleRate))
                return
            }
            let qs = butterworthQs(sections: setting.slope.sectionCount)
            for (index, butterworth) in qs.enumerated() {
                let sectionQ = index == qs.count - 1 ? butterworth * q / EqualizerBand.flatQ : butterworth
                sections.append(.pass(highPass: high, frequency: f, q: sectionQ, sampleRate: sampleRate))
            }
        }
    }

    /// The Qs of the second-order sections of a Butterworth filter made
    /// of `sections` of them, lowest first.
    static func butterworthQs(sections: Int) -> [Double] {
        let order = Double(sections * 2)
        return (0..<sections).map { k in 1 / (2 * cos(Double.pi * Double(2 * k + 1) / (2 * order))) }
    }

    /// How much `settings` change a tone at `frequency`, in decibels.
    static func response(of settings: Settings, at frequency: Double, sampleRate: Double = 48_000) -> Double {
        settings.bands.reduce(settings.output) { $0 + response(of: $1, at: frequency, sampleRate: sampleRate) }
    }

    /// How much one band changes a tone at `frequency`, in decibels.
    static func response(of setting: BandSetting, at frequency: Double, sampleRate: Double = 48_000) -> Double {
        var sections: [Biquad] = []
        appendSections(for: setting, sampleRate: sampleRate, to: &sections)
        return sections.reduce(0) { $0 + 20 * log10(max($1.magnitude(at: frequency, sampleRate: sampleRate), 1e-12)) }
    }
}

private extension ClosedRange where Bound == Double {
    func clamp(_ value: Double) -> Double { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

/// One second-order filter section, normalized so a0 is 1, with the
/// Audio EQ Cookbook's (Robert Bristow-Johnson's) coefficients.
struct Biquad: Equatable, Sendable {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    private static func normalized(_ b: (Double, Double, Double), _ a: (Double, Double, Double)) -> Biquad {
        Biquad(b0: b.0 / a.0, b1: b.1 / a.0, b2: b.2 / a.0, a1: a.1 / a.0, a2: a.2 / a.0)
    }

    /// The angle a frequency turns per sample, kept below Nyquist.
    private static func omega(_ frequency: Double, _ sampleRate: Double) -> Double {
        2 * Double.pi * frequency.clamped(between: 1, and: 0.49 * sampleRate) / sampleRate
    }

    static func bell(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> Biquad {
        let w = omega(frequency, sampleRate), alpha = sin(w) / (2 * q), a = pow(10, gain / 40), c = cos(w)
        return normalized((1 + alpha * a, -2 * c, 1 - alpha * a), (1 + alpha / a, -2 * c, 1 - alpha / a))
    }

    static func lowShelf(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> Biquad {
        let w = omega(frequency, sampleRate), alpha = sin(w) / (2 * q), a = pow(10, gain / 40), c = cos(w)
        let root = 2 * a.squareRoot() * alpha
        return normalized(
            (a * ((a + 1) - (a - 1) * c + root), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - root)),
            ((a + 1) + (a - 1) * c + root, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - root)
        )
    }

    static func highShelf(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> Biquad {
        let w = omega(frequency, sampleRate), alpha = sin(w) / (2 * q), a = pow(10, gain / 40), c = cos(w)
        let root = 2 * a.squareRoot() * alpha
        return normalized(
            (a * ((a + 1) + (a - 1) * c + root), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - root)),
            ((a + 1) - (a - 1) * c + root, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - root)
        )
    }

    /// A second-order high-pass (for a low cut) or low-pass (a high cut).
    static func pass(highPass: Bool, frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w = omega(frequency, sampleRate), alpha = sin(w) / (2 * q), c = cos(w)
        let a = (1 + alpha, -2 * c, 1 - alpha)
        return highPass
            ? normalized(((1 + c) / 2, -(1 + c), (1 + c) / 2), a)
            : normalized(((1 - c) / 2, 1 - c, (1 - c) / 2), a)
    }

    /// A first-order high-pass or low-pass, for a 6 dB per octave cut.
    static func firstOrder(highPass: Bool, frequency: Double, sampleRate: Double) -> Biquad {
        let k = tan(omega(frequency, sampleRate) / 2)
        let a1 = (k - 1) / (k + 1)
        return highPass
            ? Biquad(b0: 1 / (1 + k), b1: -1 / (1 + k), b2: 0, a1: a1, a2: 0)
            : Biquad(b0: k / (1 + k), b1: k / (1 + k), b2: 0, a1: a1, a2: 0)
    }

    /// How much it scales a tone at `frequency`: |H(e^jω)|.
    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        // e^-jω and e^-2jω.
        let (c1, s1) = (cos(w), -sin(w))
        let (c2, s2) = (cos(2 * w), -sin(2 * w))
        let numerator = (b0 + b1 * c1 + b2 * c2, b1 * s1 + b2 * s2)
        let denominator = (1 + a1 * c1 + a2 * c2, a1 * s1 + a2 * s2)
        let top = (numerator.0 * numerator.0 + numerator.1 * numerator.1).squareRoot()
        let bottom = (denominator.0 * denominator.0 + denominator.1 * denominator.1).squareRoot()
        return bottom > 0 ? top / bottom : 0
    }
}

// MARK: - Before bands

extension Equalizer {
    /// One control of an EQ saved before it had bands, when it was a low
    /// cut, a bass and a treble shelf, and a mid peak at a mid frequency.
    struct LegacyControl {
        /// Its saved kind: one of `legacyNames`.
        var name: String
        var id: UUID
        var enabled: Bool
        var number: AnimatedValue<ComponentValue>
    }

    static let legacyNames: Set<String> = ["lowCut", "bass", "mid", "midFrequency", "treble"]

    /// A Q an octave wide, the old mid's.
    static let octaveQ = 2.0.squareRoot()

    /// The bands that play `legacy` as it was heard: the low cut as a
    /// 12 dB low cut (off when it sat at 20 Hz throughout, as it was
    /// then), bass as the low shelf at 100 Hz, the mid as Bell 2 an octave
    /// wide at the mid frequency, and treble as the high shelf at 8 kHz.
    /// Old controls keep their IDs; the other bands are off.
    static func controls(migrating legacy: [LegacyControl]) -> [EffectControl] {
        var controls = Effect(kind: .equalizer).controls
        func old(_ name: String) -> LegacyControl? { legacy.first { $0.name == name } }
        func first(_ value: ComponentValue) -> Double { value.values.first ?? 0 }
        func mapped(_ number: AnimatedValue<ComponentValue>, _ make: (Double) -> [Double]) -> AnimatedValue<ComponentValue> {
            AnimatedValue(
                ComponentValue(values: make(first(number.value))),
                keyframes: number.keyframes.map {
                    $0.with(value: ComponentValue(values: make(first($0.value))))
                }
            )
        }
        func set(_ band: EqualizerBand, from control: LegacyControl, enabled: Bool, number: AnimatedValue<ComponentValue>) {
            guard let index = controls.firstIndex(where: { $0.kind == band.controlKind }) else { return }
            controls[index].id = control.id
            controls[index].enabled = enabled
            controls[index].number = number
        }

        if let lowCut = old("lowCut") {
            let cutAt = lowCut.number.isAnimated ? lowCut.number.keyframes.map { first($0.value) } : [first(lowCut.number.value)]
            let on = lowCut.enabled && cutAt.contains { $0 > Self.frequencies.lowerBound }
            set(.lowCut, from: lowCut, enabled: on, number: mapped(lowCut.number) { [max($0, Self.frequencies.lowerBound), EqualizerBand.flatQ] })
        }
        if let bass = old("bass") {
            set(.lowShelf, from: bass, enabled: bass.enabled, number: mapped(bass.number) { [100, $0, EqualizerBand.flatQ] })
        }
        if let treble = old("treble") {
            set(.highShelf, from: treble, enabled: treble.enabled, number: mapped(treble.number) { [8000, $0, EqualizerBand.flatQ] })
        }
        if let mid = old("mid") {
            let frequency = old("midFrequency").flatMap { $0.enabled ? $0.number : nil } ?? AnimatedValue(ComponentValue(values: [1000]))
            let times = Set(mid.number.keyframes.map(\.time) + frequency.keyframes.map(\.time)).sorted()
            func at(_ time: CMTime) -> ComponentValue {
                ComponentValue(values: [first(frequency.value(at: time)), first(mid.number.value(at: time)), Self.octaveQ])
            }
            let number = times.isEmpty
                ? AnimatedValue(ComponentValue(values: [first(frequency.value), first(mid.number.value), Self.octaveQ]))
                : AnimatedValue(at(times[0]), keyframes: times.map { time in
                    let eases = mid.number.keyframe(at: time) ?? frequency.keyframe(at: time)
                    return Keyframe(time: time, value: at(time), easeIn: eases?.easeIn, easeOut: eases?.easeOut)
                })
            set(.bell2, from: mid, enabled: mid.enabled, number: number)
        }
        return controls
    }
}
