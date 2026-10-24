import Foundation

// The arithmetic behind the Keyframing effects (see
// docs/keyframing-effects.md): signals and reshaped curves sampled once per
// frame, and the reduction that keeps only the keyframes a curve needs.
// Nothing here knows about clips or projects; `Keyframing.swift` samples the
// clip and writes the result.

enum KeyframeGenerators {
    // MARK: Noise

    /// A well-mixed 64-bit hash (SplitMix64's finalizer), so the same seed
    /// gives the same wiggle on every Mac and in every run.
    static func hash(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A random number in -1...1 for one lattice point of one stream.
    static func lattice(_ index: Int, stream: UInt64) -> Double {
        let mixed = hash(stream &* 0x1000_0000_01B3 ^ UInt64(bitPattern: Int64(index)))
        // The top 53 bits, as a fraction in 0..<1.
        return Double(mixed >> 11) / Double(UInt64(1) << 53) * 2 - 1
    }

    /// One-dimensional noise at `x` (lattice points one unit apart), in
    /// about -1...1. Smooth is Perlin's gradient noise, which passes through
    /// zero at each lattice point with a random slope; jagged joins random
    /// values with straight lines.
    static func noise(_ x: Double, stream: UInt64, smooth: Bool) -> Double {
        let cell = Int(floor(x))
        let t = x - Double(cell)
        if smooth {
            let a = lattice(cell, stream: stream) * t
            let b = lattice(cell + 1, stream: stream) * (t - 1)
            let fade = t * t * t * (t * (t * 6 - 15) + 10)
            // Gradient noise peaks at half its gradients' size.
            return (a + (b - a) * fade) * 2
        }
        let a = lattice(cell, stream: stream)
        let b = lattice(cell + 1, stream: stream)
        return a + (b - a) * t
    }

    /// Noise summed over octaves, each twice as fast and half as strong as
    /// the last, scaled back to about -1...1.
    static func fractalNoise(_ x: Double, octaves: Int, stream: UInt64, smooth: Bool) -> Double {
        var total = 0.0, weight = 1.0, weights = 0.0, scale = 1.0
        for octave in 0..<max(octaves, 1) {
            total += weight * noise(x * scale, stream: stream &+ UInt64(octave) &* 7919, smooth: smooth)
            weights += weight
            weight /= 2
            scale *= 2
        }
        return total / weights
    }

    // MARK: Waves

    /// One cycle of `wave` at `cycles` (a whole number is the start of a
    /// cycle), in -1...1. Every wave starts at zero, or its top for a
    /// square, and rises.
    static func wave(_ wave: OscillatorWave, at cycles: Double) -> Double {
        let u = cycles - floor(cycles)
        switch wave {
        case .sine: return sin(2 * .pi * u)
        case .triangle:
            let shifted = u - 0.25 - floor(u - 0.25)
            return 2 * abs(2 * shifted - 1) - 1
        case .square: return u < 0.5 ? 1 : -1
        case .sawtooth:
            let shifted = u + 0.5 - floor(u + 0.5)
            return 2 * shifted - 1
        }
    }

    /// How far a fade at both ends of a span lets a signal through at
    /// `elapsed` seconds into it: 0 at the ends, 1 once `fade` seconds in,
    /// eased.
    static func fadeEnvelope(elapsed: Double, total: Double, fade: Double) -> Double {
        guard fade > 0 else { return 1 }
        let x = (min(elapsed, total - elapsed) / fade).clamped(between: 0, and: 1)
        return x * x * (3 - 2 * x)
    }

    // MARK: Beats

    /// A beat chosen to drive Beat Keys: where it falls, in seconds from the
    /// start of the range, and how high it pulses.
    struct Pulse: Equatable {
        var time: Double
        var height: Double
    }

    /// Beat Keys' signal at `time` (seconds from the start of the range).
    /// `pulses` are in time order; `decay` is in seconds.
    static func beatSignal(at time: Double, pulses: [Pulse], shape: BeatShape, decay: Double) -> Double {
        // The last pulse at or before `time`.
        var low = 0, high = pulses.count
        while low < high {
            let middle = (low + high) / 2
            if pulses[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        let index = low - 1
        guard index >= 0 else { return 0 }
        let pulse = pulses[index]
        let since = time - pulse.time
        let progress = decay > 0 ? min(since / decay, 1) : 1
        let eased = 1 - (1 - progress) * (1 - progress)
        switch shape {
        case .pulse:
            return decay > 0 ? pulse.height * (1 - eased) : (since == 0 ? pulse.height : 0)
        case .step:
            // Climbs by each beat's height, over the decay.
            let below = pulses[..<index].reduce(0) { $0 + $1.height }
            return below + pulse.height * eased
        case .ramp:
            // Rises from nothing at a beat to its height at the next.
            guard index + 1 < pulses.count else { return 0 }
            let span = pulses[index + 1].time - pulse.time
            return span > 0 ? pulse.height * since / span : 0
        case .alternate:
            // Up on every other beat and back down on the rest, moving over
            // the decay.
            let up = index % 2 == 0
            let from = up ? 0 : pulses[index - 1].height
            let to = up ? pulse.height : 0
            return from + (to - from) * eased
        }
    }

    // MARK: Reshaping

    /// `samples` averaged over a window of `width` samples centered on
    /// each, held at the first and last sample past the ends.
    static func smoothed(_ samples: [[Double]], width: Int) -> [[Double]] {
        guard width > 1, let count = samples.first?.count else { return samples }
        let before = (width - 1) / 2, after = width - 1 - before
        return samples.indices.map { index in
            var sum = [Double](repeating: 0, count: count)
            for offset in -before...after {
                let row = samples[min(max(index + offset, 0), samples.count - 1)]
                for c in 0..<min(count, row.count) { sum[c] += row[c] }
            }
            return sum.map { $0 / Double(width) }
        }
    }

    /// Where Looper reads the curve for source second `time`, when the
    /// curve's keyframes span `start...end`, and how much each cycle adds
    /// for Offset: the time to read, and how many spans away it is.
    static func loopRead(_ time: Double, start: Double, end: Double, mode: LoopMode) -> (time: Double, cycles: Double) {
        let span = end - start
        guard span > 0 else { return (time, 0) }
        let cycles = floor((time - start) / span)
        let within = time - start - cycles * span
        switch mode {
        case .cycle, .offset: return (start + within, cycles)
        case .pingPong:
            let backward = Int(cycles).modulo(2) == 1
            return (backward ? end - within : start + within, 0)
        case .continue: return (time, 0)
        }
    }

    /// Overshoot's bounce `elapsed` seconds after a keyframe the curve
    /// arrived at with `velocity` (per second): a mass on a damped spring,
    /// pushed by that velocity and settling back to nothing.
    static func bounce(elapsed: Double, velocity: Double, stiffness: Double, damping: Double, mass: Double) -> Double {
        guard elapsed > 0, velocity != 0, mass > 0 else { return 0 }
        let natural = sqrt(stiffness / mass)
        let decay = damping / (2 * mass)
        if decay < natural {
            let damped = sqrt(natural * natural - decay * decay)
            return velocity * exp(-decay * elapsed) * sin(damped * elapsed) / damped
        }
        // Damped too much to swing: it only runs on and comes back.
        return velocity * elapsed * exp(-decay * elapsed)
    }

    // MARK: Reduction

    /// The indices of the samples to keep as keyframes so that straight
    /// lines between them stay within `tolerance` of every sample, for each
    /// component, at its own `times` (Ramer–Douglas–Peucker). The first and
    /// last are always kept.
    static func reduced(times: [Double], samples: [[Double]], tolerance: [Double]) -> [Int] {
        let count = min(times.count, samples.count)
        guard count > 2 else { return Array(0..<count) }
        var keep = [Bool](repeating: false, count: count)
        keep[0] = true
        keep[count - 1] = true
        var spans = [(0, count - 1)]
        while let (first, last) = spans.popLast() {
            guard last - first > 1 else { continue }
            let span = times[last] - times[first]
            var worst = 0.0, worstIndex = -1
            for index in (first + 1)..<last {
                let fraction = span > 0 ? (times[index] - times[first]) / span : 0
                for c in tolerance.indices where c < samples[index].count {
                    let line = samples[first][c] + (samples[last][c] - samples[first][c]) * fraction
                    let error = abs(samples[index][c] - line) / max(tolerance[c], 1e-12)
                    if error > worst {
                        worst = error
                        worstIndex = index
                    }
                }
            }
            if worst > 1, worstIndex >= 0 {
                keep[worstIndex] = true
                spans.append((first, worstIndex))
                spans.append((worstIndex, last))
            }
        }
        return keep.indices.filter { keep[$0] }
    }

    /// The tolerance for each component: `percent` of how far its samples
    /// range, or next to nothing for one that doesn't move, so a flat
    /// curve keeps only its ends.
    static func tolerances(_ samples: [[Double]], percent: Double) -> [Double] {
        guard let count = samples.first?.count else { return [] }
        return (0..<count).map { c in
            let values = samples.map { c < $0.count ? $0[c] : 0 }
            let spread = (values.max() ?? 0) - (values.min() ?? 0)
            return max(spread * percent / 100, 1e-9)
        }
    }
}
