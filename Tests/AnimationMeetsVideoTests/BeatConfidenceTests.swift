import Foundation
import Testing
@testable import AnimationMeetsVideo

/// SplitMix64, so the material below is the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Test material at the detector's sample rate.
private struct Material {
    static let rate = BeatDetector.sampleRate
    var generator: SeededGenerator

    init(seed: UInt64) { generator = SeededGenerator(state: seed) }

    mutating func noise(_ seconds: Double, level: Float) -> [Float] {
        (0..<Int(seconds * Self.rate)).map { _ in Float.random(in: -1...1, using: &generator) * level }
    }

    static func mix(_ sound: [Float], into samples: inout [Float], at seconds: Double) {
        let start = Int(seconds * rate)
        for index in sound.indices where samples.indices.contains(start + index) {
            samples[start + index] += sound[index]
        }
    }

    /// A short decaying noise burst, like a drum hit.
    mutating func click(level: Float) -> [Float] {
        (0..<Int(0.03 * Self.rate)).map { index in
            Float.random(in: -1...1, using: &generator) * Float(exp(-Double(index) / (0.006 * Self.rate))) * level
        }
    }

    /// High-passed noise, decaying fast: a closed hi-hat.
    mutating func hat(level: Float) -> [Float] {
        var previous: Float = 0
        return (0..<Int(0.04 * Self.rate)).map { index in
            let white = Float.random(in: -1...1, using: &generator)
            defer { previous = white }
            return (white - previous) * Float(exp(-Double(index) / (0.008 * Self.rate))) * level
        }
    }

    static func kick(level: Float) -> [Float] {
        (0..<Int(0.15 * rate)).map { index in
            let time = Double(index) / rate
            return Float(sin(2 * .pi * (50 * time + 2 * (1 - exp(-time * 30)))) * exp(-time * 18)) * level
        }
    }

    mutating func clicks(at times: [Double], seconds: Double, level: Float, floor: Float) -> [Float] {
        var samples = noise(seconds, level: floor)
        for time in times { Self.mix(click(level: level), into: &samples, at: time) }
        return samples
    }

    /// Kick on every beat, snare on 2 and 4, hats on the eighths (louder on
    /// the beat), over a
    /// held chord, each hit up to `looseness` seconds off the grid.
    mutating func drums(bpm: Double, seconds: Double, level: Float, looseness: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * Self.rate))
        let beat = 60 / bpm
        var time = 0.3, count = 0
        while time < seconds {
            func off(_ generator: inout SeededGenerator) -> Double {
                looseness > 0 ? Double.random(in: -looseness...looseness, using: &generator) : 0
            }
            Self.mix(Self.kick(level: level), into: &samples, at: time + off(&generator))
            if count % 2 == 1 { Self.mix(click(level: level * 0.7), into: &samples, at: time + off(&generator)) }
            Self.mix(hat(level: level * 0.3), into: &samples, at: time + off(&generator))
            Self.mix(hat(level: level * 0.2), into: &samples, at: time + beat / 2 + off(&generator))
            time += beat
            count += 1
        }
        for index in samples.indices {
            let time = Double(index) / Self.rate
            samples[index] += Float(sin(2 * .pi * 220 * time) + 0.5 * sin(2 * .pi * 277 * time)) * level * 0.15
        }
        return samples
    }

    /// Phrases of voiced syllables with gliding pitch and the odd hiss of a
    /// consonant, separated by pauses: speech, as far as onsets go.
    mutating func speech(_ seconds: Double, level: Float) -> [Float] {
        var samples = noise(seconds, level: level * 0.002)
        var time = 0.2
        while time < seconds {
            for _ in 0..<Int.random(in: 3...12, using: &generator) where time < seconds {
                if Bool.random(using: &generator) {
                    let length = Double.random(in: 0.03...0.09, using: &generator)
                    Self.mix(noise(length, level: level * 0.25), into: &samples, at: time)
                    time += length
                }
                let length = Double.random(in: 0.08...0.28, using: &generator)
                let pitch = Double.random(in: 100...220, using: &generator)
                let glide = Double.random(in: -40...40, using: &generator)
                let loudness = Float.random(in: 0.4...1, using: &generator)
                var phase = 0.0
                let syllable = (0..<Int(length * Self.rate)).map { index -> Float in
                    let progress = Double(index) / (length * Self.rate)
                    phase += 2 * .pi * (pitch + glide * progress) / Self.rate
                    let voice = (1...8).map { sin(Double($0) * phase) / Double($0) }.reduce(0, +)
                    return Float(voice * pow(sin(.pi * progress), 2)) * level * loudness
                }
                Self.mix(syllable, into: &samples, at: time)
                time += length + Double.random(in: 0.02...0.15, using: &generator)
            }
            time += Double.random(in: 0.25...0.9, using: &generator)
        }
        return samples
    }

    /// Noise whose loudness wanders, like wind or a crowd.
    mutating func wanderingNoise(_ seconds: Double, level: Float) -> [Float] {
        var gain: Float = 0.5
        return (0..<Int(seconds * Self.rate)).map { index in
            if index % 512 == 0 { gain = min(1, max(0.05, gain + Float.random(in: -0.08...0.08, using: &generator))) }
            return Float.random(in: -1...1, using: &generator) * level * gain
        }
    }

    /// Clicks at random, `perSecond` on average.
    mutating func randomClicks(_ seconds: Double, perSecond: Double, level: Float) -> [Float] {
        var times: [Double] = []
        var time = -log(Double.random(in: 1e-9...1, using: &generator)) / perSecond
        while time < seconds {
            times.append(time)
            time += -log(Double.random(in: 1e-9...1, using: &generator)) / perSecond
        }
        return clicks(at: times, seconds: seconds, level: level, floor: level * 0.001)
    }
}

private func beats(in samples: [Float]) throws -> BeatTracker.Result? {
    let analyzer = OnsetAnalyzer()
    samples.withUnsafeBufferPointer { analyzer.append($0) }
    return try BeatTracker.track(envelope: analyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond)
}

@Suite struct BeatConfidenceTests {
    private static let seeds: [UInt64] = [1, 2, 3]
    private let length = 20.0

    @Test(arguments: seeds) func noiseHasNoBeats(seed: UInt64) throws {
        var material = Material(seed: seed)
        #expect(try beats(in: material.noise(length, level: 0.3)) == nil)
        #expect(try beats(in: material.wanderingNoise(length, level: 0.4)) == nil)
    }

    @Test(arguments: seeds) func aNoiseFloorAloneHasNoBeats(seed: UInt64) throws {
        // Like dither in a stem that is otherwise silent.
        var material = Material(seed: seed)
        #expect(try beats(in: material.noise(length, level: 1e-5)) == nil)
    }

    @Test(arguments: seeds) func speechHasNoBeats(seed: UInt64) throws {
        var material = Material(seed: seed)
        #expect(try beats(in: material.speech(length, level: 0.3)) == nil)
        #expect(try beats(in: material.speech(length, level: 0.02)) == nil)
    }

    @Test(arguments: seeds) func isolatedOrRandomTransientsHaveNoBeats(seed: UInt64) throws {
        var material = Material(seed: seed)
        #expect(try beats(in: material.clicks(at: [6], seconds: length, level: 0.8, floor: 0)) == nil)
        #expect(try beats(in: material.clicks(at: [1.3, 4.7, 8.2], seconds: length, level: 0.8, floor: 0)) == nil)
        #expect(try beats(in: material.clicks(at: [1.3, 2.1, 4.7, 8.2, 15], seconds: length, level: 0.8, floor: 0.001)) == nil)
        #expect(try beats(in: material.randomClicks(length, perSecond: 2, level: 0.5)) == nil)
        #expect(try beats(in: material.randomClicks(length, perSecond: 5, level: 0.5)) == nil)
    }

    @Test func silenceHasNoBeats() throws {
        #expect(try beats(in: [Float](repeating: 0, count: Int(length * BeatDetector.sampleRate))) == nil)
    }

    @Test(arguments: seeds) func quietRhythmIsStillFound(seed: UInt64) throws {
        var material = Material(seed: seed)
        let drums = try #require(try beats(in: material.drums(bpm: 128, seconds: length, level: 0.02, looseness: 0.01)))
        #expect(abs(drums.beatsPerMinute - 128) < 3)
        #expect(drums.confidence.isSteadyBeat)

        let times = Array(stride(from: 0.2, to: length, by: 0.6))
        let clicks = try #require(try beats(in: material.clicks(at: times, seconds: length, level: 0.02, floor: 0.01)))
        #expect(abs(clicks.beatsPerMinute - 100) < 3)
    }

    @Test(arguments: seeds) func aLooseDrumPatternIsFound(seed: UInt64) throws {
        var material = Material(seed: seed)
        let result = try #require(try beats(in: material.drums(bpm: 75, seconds: length, level: 0.3, looseness: 0.02)))
        #expect(abs(result.beatsPerMinute - 75) < 3)
    }

    @Test func aClearPulseIsConfident() throws {
        var material = Material(seed: 7)
        let result = try #require(try beats(in: material.clicks(at: Array(stride(from: 0.2, to: length, by: 0.5)), seconds: length, level: 0.8, floor: 0)))
        let confidence = result.confidence
        #expect(confidence.periodicity > 0.9)
        #expect(confidence.supportedShare > 0.9)
        #expect(confidence.agreement > 5)
    }
}
