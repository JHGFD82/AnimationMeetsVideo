import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The EQ's bands, their filters and curves, and EQs saved before bands.
@Suite struct EqualizerTests {
    private func setting(_ band: EqualizerBand, _ frequency: Double, gain: Double = 0, q: Double? = nil, slope: EqualizerSlope = .db12) -> Equalizer.BandSetting {
        Equalizer.BandSetting(band: band, frequency: frequency, gain: gain, q: q ?? band.defaultQ, slope: slope)
    }

    private func response(_ setting: Equalizer.BandSetting, at frequency: Double) -> Double {
        Equalizer.response(of: setting, at: frequency)
    }

    /// An EQ with `band` on and set to `values`.
    private func equalizer(_ changes: [(EqualizerBand, [Double])], slope: (ControlKind, EqualizerSlope)? = nil) -> Effect {
        var effect = Effect(kind: .equalizer)
        for (band, values) in changes {
            let index = effect.controls.firstIndex { $0.kind == band.controlKind }!
            effect.controls[index].enabled = true
            effect.controls[index].number = AnimatedValue(ComponentValue(values: values))
        }
        if let (kind, value) = slope, let index = effect.controls.firstIndex(where: { $0.kind == kind }) {
            effect.controls[index].choice = value.rawValue
        }
        return effect
    }

    // MARK: Curves

    @Test func aBellBoostsItsCenterByItsGainAndLeavesFarOffAlone() {
        let bell = setting(.bell2, 1000, gain: 6, q: 1)
        #expect(abs(response(bell, at: 1000) - 6) < 0.01)
        #expect(abs(response(bell, at: 100)) < 0.1)
        #expect(abs(response(setting(.bell2, 1000, gain: -12, q: 1), at: 1000) + 12) < 0.01)
    }

    @Test func shelvesAreHalfwayAtTheirFrequency() {
        let low = setting(.lowShelf, 100, gain: -12)
        #expect(abs(response(low, at: 100) + 6) < 0.05)
        #expect(abs(response(low, at: 20) + 12) < 0.1)
        #expect(abs(response(low, at: 2000)) < 0.05)
        let high = setting(.highShelf, 8000, gain: 12)
        #expect(abs(response(high, at: 8000) - 6) < 0.05)
        #expect(abs(response(high, at: 200)) < 0.05)
    }

    @Test func cutsAreThreeDecibelsDownAtTheirFrequencyAndFallAtTheirSlope() {
        for slope in EqualizerSlope.allCases {
            let cut = setting(.lowCut, 1000, slope: slope)
            #expect(abs(response(cut, at: 1000) + 3.01) < 0.05)
            #expect(abs(response(cut, at: 20_000)) < 0.1)
            // An octave down is the slope's worth, within a fraction near
            // the knee.
            let octave = response(cut, at: 500)
            let steepness = Double(slope.rawValue)!
            #expect(octave < -steepness * 0.9 && octave > -steepness * 1.2, "\(slope.name): \(octave)")
        }
        let high = setting(.highCut, 1000, slope: .db24)
        #expect(abs(response(high, at: 1000) + 3.01) < 0.05)
        #expect(response(high, at: 2000) < -21)
        #expect(abs(response(high, at: 50)) < 0.05)
    }

    @Test func aResonantCutBumpsUpBeforeItFalls() {
        let resonant = setting(.lowCut, 200, q: 4)
        #expect(response(resonant, at: 200) > 10)
    }

    @Test func theWholeCurveAddsTheBandsAndTheOutput() {
        let settings = Equalizer.Settings(bands: [setting(.lowShelf, 100, gain: -6), setting(.bell3, 2500, gain: 4, q: 2)], output: 2)
        let at = 2500.0
        let expected = response(settings.bands[0], at: at) + response(settings.bands[1], at: at) + 2
        #expect(abs(Equalizer.response(of: settings, at: at) - expected) < 1e-9)
    }

    @Test func butterworthSectionsHaveTheirTextbookQs() {
        let four = Equalizer.butterworthQs(sections: 2)
        #expect(abs(four[0] - 0.5412) < 1e-4 && abs(four[1] - 1.3066) < 1e-4)
        #expect(Equalizer.butterworthQs(sections: 4).count == 4)
    }

    // MARK: Settings

    @Test func aNewEQHasEveryBandOffAndDoesNothing() {
        let effect = Effect(kind: .equalizer)
        #expect(effect.controls.map(\.kind) == Equalizer.controlKinds)
        #expect(effect.isNoOp)
        #expect(Equalizer.settings(of: effect, at: .zero).isFlat)
        #expect(Equalizer.settings(of: effect, at: .zero).bands.isEmpty)
    }

    @Test func aBandThatIsOnAtZeroDecibelsStillDoesNothing() {
        let bell = equalizer([(.bell1, [250, 0, 1])])
        #expect(bell.isNoOp)
        #expect(Equalizer.settings(of: bell, at: .zero).isFlat)
        let cut = equalizer([(.lowCut, [80, EqualizerBand.flatQ])])
        #expect(!cut.isNoOp)
        #expect(!Equalizer.settings(of: cut, at: .zero).isFlat)
    }

    @Test func settingsListTheBandsThatAreOnWithTheirSlopes() {
        let effect = equalizer([(.highCut, [12_000, 0.7071]), (.bell2, [900, -3, 2])], slope: (.eqHighCutSlope, .db48))
        let settings = Equalizer.settings(of: effect, at: .zero)
        #expect(settings.bands.map(\.band) == [.bell2, .highCut])
        #expect(settings.bands[1].slope == .db48)
        #expect(settings.bands[0].frequency == 900 && settings.bands[0].gain == -3 && settings.bands[0].q == 2)
    }

    @Test func valuesOutsideTheirRangesAreHeldInside() {
        var effect = equalizer([(.bell1, [5, 40, 50])])
        let band = Equalizer.settings(of: effect, at: .zero).bands[0]
        #expect(band.frequency == 20 && band.gain == 24 && band.q == 18)
        let index = effect.controls.firstIndex { $0.kind == .eqBell1 }!
        effect.controls[index].setComponent(0, to: 50_000, at: .zero)
        effect.controls[index].setComponent(2, to: 0, at: .zero)
        #expect(effect.controls[index].values(at: .zero) == [20_000, 40, 0.1])
    }

    @Test func sweepsMoveOnALogScale() {
        let from = Equalizer.Settings(bands: [setting(.bell1, 100, gain: -12, q: 1)])
        let to = Equalizer.Settings(bands: [setting(.bell1, 400, gain: 12, q: 4)], output: 6)
        let middle = from.interpolated(to: to, fraction: 0.5)
        #expect(abs(middle.bands[0].frequency - 200) < 1e-9)
        #expect(abs(middle.bands[0].q - 2) < 1e-9)
        #expect(middle.bands[0].gain == 0 && middle.output == 3)
        // Different bands on can't be swept between.
        let other = Equalizer.Settings(bands: [setting(.bell2, 400)])
        #expect(from.interpolated(to: other, fraction: 0.5) == other)
    }

    @Test func eachComponentHasItsOwnUnit() {
        #expect(ControlKind.eqBell1.label(800, component: 0) == "800 Hz")
        #expect(ControlKind.eqBell1.label(-4.5, component: 1) == "-4.5 dB")
        #expect(ControlKind.eqLowCut.componentNames == ["Frequency", "Q"])
        #expect(ControlKind.eqLowCut.unit(ofComponent: 1) == "")
    }

    // MARK: Before bands

    private func legacy(_ name: String, _ value: Double, enabled: Bool = true) -> Equalizer.LegacyControl {
        Equalizer.LegacyControl(name: name, id: UUID(), enabled: enabled, number: AnimatedValue(ComponentValue(values: [value])))
    }

    @Test func anOldEQBecomesTheBandsItSoundedLike() {
        let bass = legacy("bass", -6)
        let controls = Equalizer.controls(migrating: [legacy("lowCut", 20), bass, legacy("mid", 3), legacy("midFrequency", 2000), legacy("treble", -24)])
        var effect = Effect(kind: .equalizer)
        effect.controls = controls
        #expect(controls.map(\.kind) == Equalizer.controlKinds)
        #expect(effect.control(.eqLowShelf)?.id == bass.id)
        let settings = Equalizer.settings(of: effect, at: .zero)
        // The low cut sat at 20 Hz, which was off.
        #expect(settings.bands.map(\.band) == [.lowShelf, .bell2, .highShelf])
        #expect(settings.bands[0].frequency == 100 && settings.bands[0].gain == -6)
        #expect(settings.bands[1].frequency == 2000 && settings.bands[1].gain == 3 && abs(settings.bands[1].q - 2.0.squareRoot()) < 1e-9)
        #expect(settings.bands[2].frequency == 8000 && settings.bands[2].gain == -24)
    }

    @Test func anOldAnimatedMidKeepsItsKeyframesAndALowCutAbove20HzStaysOn() {
        let second = CMTime(value: 1, timescale: 1)
        var frequency = legacy("midFrequency", 0)
        frequency.number = AnimatedValue(ComponentValue(values: [500]), keyframes: [
            Keyframe(time: .zero, value: ComponentValue(values: [500]), easeIn: nil, easeOut: nil),
            Keyframe(time: second, value: ComponentValue(values: [2000]), easeIn: nil, easeOut: nil),
        ])
        let controls = Equalizer.controls(migrating: [legacy("lowCut", 80), legacy("mid", 4), frequency])
        let mid = controls.first { $0.kind == .eqBell2 }!
        #expect(mid.number.keyframes.map(\.time) == [.zero, second])
        #expect(mid.values(at: second) == [2000, 4, 2.0.squareRoot()])
        let cut = controls.first { $0.kind == .eqLowCut }!
        #expect(cut.enabled && cut.values(at: .zero) == [80, EqualizerBand.flatQ])
        #expect(!controls.first { $0.kind == .eqLowShelf }!.enabled)
    }
}

/// The EQ as a tap runs it.
@Suite struct EqualizerFilterTests {
    /// The level in decibels a 0 dBFS sine at `frequency` comes out at
    /// after `effect`, once the filters have settled.
    private func measuredGain(of effect: Effect, at frequency: Double, sampleRate: Double = 48_000) throws -> Double {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let filter = try #require(EqualizerFilter(effectID: effect.id, format: format.streamDescription.pointee, maxFrames: 4096))
        filter.apply(effect, from: .zero, to: .zero)
        let frames = 4096
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        var peak: Float = 0
        // Twenty buffers, measuring the last few once the filters settle.
        for round in 0..<20 {
            for channel in 0..<2 {
                let data = buffer.floatChannelData![channel]
                for index in 0..<frames {
                    data[index] = Float(sin(2 * Double.pi * frequency * Double(round * frames + index) / sampleRate))
                }
            }
            filter.process(buffer.mutableAudioBufferList, frames: frames)
            if round >= 16 {
                for index in 0..<frames { peak = max(peak, abs(buffer.floatChannelData![1][index])) }
            }
        }
        return 20 * log10(Double(peak))
    }

    private func equalizer(_ band: EqualizerBand, _ values: [Double], output: Double = 0) -> Effect {
        var effect = Effect(kind: .equalizer)
        let index = effect.controls.firstIndex { $0.kind == band.controlKind }!
        effect.controls[index].enabled = true
        effect.controls[index].number = AnimatedValue(ComponentValue(values: values))
        if let out = effect.controls.firstIndex(where: { $0.kind == .eqOutput }) {
            effect.controls[out].number = AnimatedValue(ComponentValue(values: [output]))
        }
        return effect
    }

    @Test func whatIsHeardIsTheCurveThatIsDrawn() throws {
        let cases: [(EqualizerBand, [Double], Double)] = [
            (.bell2, [1000, 9, 1.5], 1000), (.bell2, [1000, 9, 1.5], 1400),
            (.lowShelf, [200, -12, 0.7071], 100), (.highShelf, [6000, 6, 0.7071], 9000),
            (.lowCut, [400, 0.7071], 250), (.highCut, [3000, 2], 2800),
        ]
        for sampleRate in [44_100.0, 48_000, 96_000] {
            for (band, values, frequency) in cases {
                let effect = equalizer(band, values, output: -2)
                let expected = Equalizer.response(of: Equalizer.settings(of: effect, at: .zero), at: frequency, sampleRate: sampleRate)
                let heard = try measuredGain(of: effect, at: frequency, sampleRate: sampleRate)
                #expect(abs(heard - expected) < 0.1, "\(band.name) at \(frequency) Hz, \(sampleRate): heard \(heard), drawn \(expected)")
            }
        }
    }

    @Test func aFlatEQPassesSoundUnchanged() throws {
        let effect = equalizer(.bell3, [2500, 0, 1])
        #expect(abs(try measuredGain(of: effect, at: 3000)) < 0.01)
    }
}

/// The sound an EQ's graph shows behind its curves.
@Suite struct EqualizerSpectrumTests {
    /// Records `seconds` of a sine at `frequency` as buffers of 512, from
    /// source time 10 s, the same before and after.
    private func record(_ id: UUID, frequency: Double, seconds: Double = 0.5) {
        let rate = 48_000.0, size = 512
        var played = 0
        while Double(played) < seconds * rate {
            let samples = (0..<size).map { Float(sin(2 * Double.pi * frequency * Double(played + $0) / rate)) }
            samples.withUnsafeBufferPointer { buffer in
                EqualizerSpectrum.shared.record(
                    id, pre: buffer.baseAddress!, post: buffer.baseAddress!, frames: size,
                    start: 10 + Double(played) / rate, end: 10 + Double(played + size) / rate, sampleRate: rate
                )
            }
            played += size
        }
    }

    @Test func aWatchedEQShowsItsToneAtThePlayhead() throws {
        let id = UUID()
        EqualizerSpectrum.shared.watch(id)
        defer { EqualizerSpectrum.shared.unwatch(id) }
        record(id, frequency: 1000)
        let reading = try #require(EqualizerSpectrum.shared.levels(of: id, pre: false, at: 10.4))
        let loudest = reading.decibels.indices.max { reading.decibels[$0] < reading.decibels[$1] }!
        #expect(abs(Double(loudest) * reading.binWidth - 1000) < reading.binWidth * 1.5)
        // A full-scale sine reads near 0 dBFS, less what falls between bins.
        #expect(reading.decibels[loudest] > -2 && reading.decibels[loudest] < 0.5)
        #expect(reading.decibels[loudest * 3] < -60)
    }

    @Test func nothingIsShownForAMomentThatWasntPlayedOrAnEQNotWatched() {
        let id = UUID()
        record(id, frequency: 1000)
        #expect(EqualizerSpectrum.shared.levels(of: id, pre: false, at: 10.4) == nil)
        EqualizerSpectrum.shared.watch(id)
        defer { EqualizerSpectrum.shared.unwatch(id) }
        record(id, frequency: 1000)
        // Before a whole window has played, and after the recording ends.
        #expect(EqualizerSpectrum.shared.levels(of: id, pre: true, at: 10.05) == nil)
        #expect(EqualizerSpectrum.shared.levels(of: id, pre: true, at: 20) == nil)
    }
}
