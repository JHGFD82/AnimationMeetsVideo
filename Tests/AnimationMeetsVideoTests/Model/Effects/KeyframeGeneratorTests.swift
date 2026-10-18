import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct KeyframeGeneratorTests {
    @Test func wavesStartAtZeroAndRise() {
        let sine = KeyframeGenerators.wave(.sine, at: 0.25)
        #expect(abs(sine - 1) < 1e-12)
        #expect(abs(KeyframeGenerators.wave(.triangle, at: 0)) < 1e-12)
        #expect(abs(KeyframeGenerators.wave(.triangle, at: 0.25) - 1) < 1e-12)
        #expect(abs(KeyframeGenerators.wave(.triangle, at: 0.75) + 1) < 1e-12)
        #expect(KeyframeGenerators.wave(.square, at: 0.1) == 1)
        #expect(KeyframeGenerators.wave(.square, at: 1.6) == -1)
        #expect(abs(KeyframeGenerators.wave(.sawtooth, at: 0.25) - 0.5) < 1e-12)
    }

    @Test func noiseIsTheSameEveryTimeAndStaysInRange() {
        let a = (0..<500).map { KeyframeGenerators.fractalNoise(Double($0) * 0.037, octaves: 3, stream: 7, smooth: true) }
        let b = (0..<500).map { KeyframeGenerators.fractalNoise(Double($0) * 0.037, octaves: 3, stream: 7, smooth: true) }
        let other = (0..<500).map { KeyframeGenerators.fractalNoise(Double($0) * 0.037, octaves: 3, stream: 8, smooth: true) }
        #expect(a == b)
        #expect(a != other)
        #expect(a.allSatisfy { abs($0) <= 1.01 })
        // Smooth noise crosses zero on the lattice.
        #expect(KeyframeGenerators.noise(3, stream: 7, smooth: true) == 0)
    }

    @Test func reductionKeepsEverySampleWithinTolerance() {
        let times = (0..<400).map { Double($0) / 24 }
        let samples = times.map { t in [sin(t * 3) * 50 + KeyframeGenerators.noise(t * 2, stream: 1, smooth: true) * 20, t * 4] }
        let tolerance = KeyframeGenerators.tolerances(samples, percent: 0.5)
        let kept = KeyframeGenerators.reduced(times: times, samples: samples, tolerance: tolerance)
        #expect(kept.first == 0 && kept.last == times.count - 1)
        #expect(kept.count < times.count / 2)
        // A straight line keeps only its ends.
        #expect(kept.count > 2)
        var worst = 0.0
        for (a, b) in zip(kept, kept.dropFirst()) {
            for k in a...b {
                let fraction = (times[k] - times[a]) / (times[b] - times[a])
                for c in 0..<2 {
                    let line = samples[a][c] + (samples[b][c] - samples[a][c]) * fraction
                    worst = max(worst, abs(samples[k][c] - line) / tolerance[c])
                }
            }
        }
        #expect(worst <= 1 + 1e-9)
    }

    @Test func aStraightLineKeepsOnlyItsEnds() {
        let times = (0..<50).map(Double.init)
        let samples = times.map { [$0 * 2] }
        let kept = KeyframeGenerators.reduced(times: times, samples: samples, tolerance: KeyframeGenerators.tolerances(samples, percent: 0.5))
        #expect(kept == [0, 49])
    }

    @Test func beatShapes() {
        let pulses = [KeyframeGenerators.Pulse(time: 1, height: 10), KeyframeGenerators.Pulse(time: 2, height: 10)]
        #expect(KeyframeGenerators.beatSignal(at: 0.5, pulses: pulses, shape: .pulse, decay: 0.25) == 0)
        #expect(KeyframeGenerators.beatSignal(at: 1, pulses: pulses, shape: .pulse, decay: 0.25) == 10)
        #expect(KeyframeGenerators.beatSignal(at: 1.3, pulses: pulses, shape: .pulse, decay: 0.25) == 0)
        #expect(KeyframeGenerators.beatSignal(at: 2.5, pulses: pulses, shape: .step, decay: 0.25) == 20)
        #expect(KeyframeGenerators.beatSignal(at: 1.5, pulses: pulses, shape: .ramp, decay: 0.25) == 5)
        #expect(KeyframeGenerators.beatSignal(at: 1.5, pulses: pulses, shape: .alternate, decay: 0.25) == 10)
        #expect(KeyframeGenerators.beatSignal(at: 2.5, pulses: pulses, shape: .alternate, decay: 0.25) == 0)
    }

    @Test func loopReadsInEachMode() {
        #expect(KeyframeGenerators.loopRead(2.5, start: 0, end: 1, mode: .cycle).time == 0.5)
        #expect(KeyframeGenerators.loopRead(1.25, start: 0, end: 1, mode: .pingPong).time == 0.75)
        #expect(KeyframeGenerators.loopRead(2.25, start: 0, end: 1, mode: .pingPong).time == 0.25)
        let offset = KeyframeGenerators.loopRead(2.5, start: 0, end: 1, mode: .offset)
        #expect(offset.time == 0.5 && offset.cycles == 2)
        // Before the first keyframe, counting back.
        let before = KeyframeGenerators.loopRead(-0.25, start: 0, end: 1, mode: .offset)
        #expect(before.time == 0.75 && before.cycles == -1)
    }

    @Test func aBounceStartsAtRestAndDiesAway() {
        let start = KeyframeGenerators.bounce(elapsed: 0, velocity: 100, stiffness: 200, damping: 8, mass: 1)
        let soon = KeyframeGenerators.bounce(elapsed: 0.05, velocity: 100, stiffness: 200, damping: 8, mass: 1)
        let late = KeyframeGenerators.bounce(elapsed: 3, velocity: 100, stiffness: 200, damping: 8, mass: 1)
        #expect(start == 0)
        #expect(soon > 0)
        #expect(abs(late) < 0.01)
    }
}
