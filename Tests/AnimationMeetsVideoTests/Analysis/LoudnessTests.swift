import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct LoudnessTests {
    /// `seconds` of a 997 Hz sine peaking at `amplitude` on each of
    /// `channels`, interleaved.
    private func sine(amplitude: Float, seconds: Double, channels: Int = 2, rate: Double = 48_000) -> [Float] {
        let frames = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2 * .pi * 997 * Double(frame) / rate))
            for channel in 0..<channels { samples[frame * channels + channel] = value }
        }
        return samples
    }

    private func measure(_ samples: [Float], channels: Int = 2, rate: Double = 48_000) -> LoudnessMeasurement {
        var measurement = LoudnessMeasurement(sampleRate: rate, channels: channels)
        samples.withUnsafeBufferPointer { measurement.add(interleaved: $0) }
        return measurement
    }

    @Test func aFullScaleSineOnBothChannelsReadsZero() {
        let measurement = measure(sine(amplitude: 1, seconds: 5))
        #expect(abs(measurement.integrated) < 0.1)
        #expect(abs(measurement.loudestShortTerm) < 0.1)
        #expect(abs(measurement.peak - 1) < 0.001)
    }

    @Test func aTenthReadsMinusTwentyAtOtherRatesToo() {
        for rate in [44_100.0, 48_000, 96_000] {
            let measurement = measure(sine(amplitude: 0.1, seconds: 4, rate: rate), rate: rate)
            #expect(abs(measurement.integrated - -20) < 0.1)
        }
    }

    @Test func monoCountsOnBothSides() {
        let measurement = measure(sine(amplitude: 0.1, seconds: 4, channels: 1), channels: 1)
        #expect(abs(measurement.integrated - -20) < 0.1)
    }

    /// EBU R128's gates: near silence is left out, and so is anything 10 LU
    /// under the rest.
    @Test func quietStretchesAreGatedOut() {
        let loud = sine(amplitude: 0.1, seconds: 10)
        let measurement = measure(loud + sine(amplitude: 0.0001, seconds: 10) + sine(amplitude: 0.01, seconds: 10))
        #expect(abs(measurement.integrated - -20) < 0.1)
        #expect(measure(sine(amplitude: 0.00001, seconds: 2)).integrated == Loudness.silence)
    }

    @Test func theTapsMeasureTheMixsLoudness() async throws {
        let url = try AudioMixSupport.tone(frequency: 997, amplitude: 0.1, seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let (project, _, _) = try AudioMixSupport.project(playing: url, seconds: 4)
        let meter = MixLevelMeter()
        _ = try await AudioMixSupport.loudest(of: project, meter: meter)
        let loudness = try #require(meter.loudness(at: 3.9))
        #expect(abs(loudness - -20) < 0.2)
    }

    @Test func labelsRead() {
        #expect(Loudness.label(-14.24) == "−14.2")
        #expect(Loudness.label(Loudness.silence) == "−∞")
        #expect(Loudness.label(0) == "0")
    }

    @Test func theMeterReadsTheLoudnessOfWhatItRecorded() {
        let meter = MixLevelMeter()
        let rate = 48_000.0
        let samples = sine(amplitude: 0.1, seconds: 4, channels: 1)
        var weighting = [KWeighting(sampleRate: rate), KWeighting(sampleRate: rate)]
        let weighted = samples.map { sample -> Float in
            let l = weighting[0](sample), r = weighting[1](sample)
            return l * l + r * r
        }
        var copy = samples
        copy.withUnsafeMutableBufferPointer { buffer in
            weighted.withUnsafeBufferPointer { weighted in
                let channel = (buffer.baseAddress!, 1)
                meter.record(left: channel, right: channel, weighted: weighted.baseAddress, frames: samples.count, sampleRate: rate, start: 0, track: 0)
            }
        }
        let loudness = meter.loudness(at: 3.9)
        #expect(loudness != nil)
        #expect(abs((loudness ?? 0) - -20) < 0.2)
        #expect(meter.loudness(at: 20) == nil)
    }
}
