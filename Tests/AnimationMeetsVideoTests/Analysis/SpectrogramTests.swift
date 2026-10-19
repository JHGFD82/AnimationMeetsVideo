import Foundation
import Testing
@testable import AnimationMeetsVideo

/// `seconds` of a sine at `frequency` and `amplitude`, at the rate files
/// are read at.
func tone(_ frequency: Double, amplitude: Double = 1, seconds: Double) -> [Float] {
    let rate = Spectrogram.sampleRate
    return (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
}

@Suite struct SpectrogramTests {
    @Test func aFullScaleSineReadsItsPowerInItsBand() {
        let spectrogram = Spectrogram.analyze(tone(1000, seconds: 1))
        #expect(abs(spectrogram.frameCount - 51) <= 1)
        let bands = spectrogram.decibels(atSeconds: 0.5)
        let band = (0..<Spectrogram.bandCount).first { Spectrogram.edge($0 + 1) > 1000 }!
        // Mean square 0.5: −3 dB, all of it within a band or two.
        let level = AudioKeysMath.level(of: bands, from: 800, to: 1250)
        #expect(abs(level + 3) < 0.6)
        #expect(bands[band] > -6)
        #expect(bands[2] < -80)
        #expect(bands[Spectrogram.bandCount - 2] < -80)
    }

    @Test func silenceIsTheFloorAndStreamingMatchesOneGo() {
        let quiet = Spectrogram.analyze([Float](repeating: 0, count: 22_050))
        #expect(quiet.levels.allSatisfy { $0 == 0 })
        let samples = tone(300, amplitude: 0.3, seconds: 0.7) + tone(3000, amplitude: 0.3, seconds: 0.7)
        var collector = Spectrogram.Collector(sampleRate: Spectrogram.sampleRate)
        for start in stride(from: 0, to: samples.count, by: 1000) {
            samples[start..<min(start + 1000, samples.count)].withUnsafeBufferPointer { collector.add($0) }
        }
        #expect(collector.spectrogram() == Spectrogram.analyze(samples))
    }

    @Test func bandsAreLogSpacedFromTwentyHertzToTwentyKilohertz() {
        #expect(abs(Spectrogram.edge(0) - 20) < 1e-9)
        #expect(abs(Spectrogram.edge(Spectrogram.bandCount) - 20_000) < 1e-6)
        let ratio = Spectrogram.edge(10) / Spectrogram.edge(9)
        #expect(abs(ratio - Spectrogram.edge(40) / Spectrogram.edge(39)) < 1e-9)
    }
}
