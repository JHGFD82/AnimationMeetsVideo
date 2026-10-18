import Foundation

/// Loudness as ITU-R BS.1770 (and EBU R128) measures it, in LUFS: sound is
/// K-weighted (`KWeighting`), its mean square summed over the channels, and
/// read as −0.691 + 10·log10 of that. A full-scale 997 Hz sine on both
/// channels of a stereo pair reads 0 LUFS.
enum Loudness {
    /// What nothing at all reads as.
    static let silence = -Double.infinity

    /// The loudness of a mean square already summed over the channels.
    static func lufs(meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : silence
    }

    /// The mean square, summed over the channels, that reads as `lufs`.
    static func meanSquare(lufs: Double) -> Double {
        pow(10, (lufs + 0.691) / 10)
    }

    /// "−14.2", or "−∞" for silence.
    static func label(_ lufs: Double) -> String {
        guard lufs.isFinite else { return "−∞" }
        let number = NumericExpression.format(abs(lufs), maxFractionDigits: 1)
        return (lufs < 0 && number != "0" ? "−" : "") + number
    }
}

/// The K-weighting filter of one channel: a high shelf (about +4 dB above
/// 2 kHz, for the head) then a high-pass (below about 40 Hz), as two
/// biquads with BS.1770's coefficients worked out for the sample rate.
struct KWeighting: Sendable {
    private struct Biquad: Sendable {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0

        mutating func callAsFunction(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var shelf = Biquad()
    private var highPass = Biquad()

    init(sampleRate: Double) {
        // The shelf.
        var k = tan(.pi * 1681.974450955533 / sampleRate)
        var q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        shelf.b0 = (vh + vb * k / q + k * k) / a0
        shelf.b1 = 2 * (k * k - vh) / a0
        shelf.b2 = (vh - vb * k / q + k * k) / a0
        shelf.a1 = 2 * (k * k - 1) / a0
        shelf.a2 = (1 - k / q + k * k) / a0
        // The high-pass.
        k = tan(.pi * 38.13547087602444 / sampleRate)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        highPass.b0 = 1
        highPass.b1 = -2
        highPass.b2 = 1
        highPass.a1 = 2 * (k * k - 1) / a0
        highPass.a2 = (1 - k / q + k * k) / a0
    }

    /// The next sample, weighted.
    mutating func callAsFunction(_ sample: Float) -> Float {
        Float(highPass(shelf(Double(sample))))
    }

    /// Forgets what it has heard, after a jump in time.
    mutating func reset() {
        shelf.z1 = 0; shelf.z2 = 0
        highPass.z1 = 0; highPass.z2 = 0
    }
}

/// Measures a whole program's loudness as it is fed: its integrated
/// loudness (gated, as BS.1770 and EBU R128 have it), the loudest
/// short-term (3 s) and momentary (400 ms) loudness along the way, and
/// the loudest sample.
struct LoudnessMeasurement: Sendable {
    let sampleRate: Double
    private var filters: [KWeighting]
    /// Frames in each 100 ms step that blocks start on.
    private let stepFrames: Int
    /// The weighted squares, summed over channels, of the step being fed.
    private var stepSum = 0.0
    private var stepCount = 0
    /// Each finished step's mean square, summed over channels.
    private var steps: [Double] = []
    private(set) var peak: Float = 0
    private(set) var loudestMomentary = Loudness.silence
    private(set) var loudestShortTerm = Loudness.silence

    /// A mono program is measured as it plays: on both sides of a stereo
    /// pair, so twice its power.
    private let channelWeight: Double

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        filters = Array(repeating: KWeighting(sampleRate: sampleRate), count: max(1, channels))
        stepFrames = max(1, Int((sampleRate / 10).rounded()))
        channelWeight = channels == 1 ? 2 : 1
    }

    /// Feeds `frames` frames, interleaved across the channels it was made
    /// for.
    mutating func add(interleaved samples: UnsafeBufferPointer<Float>) {
        let channels = filters.count
        add(frames: samples.count / channels) { frame, channel in samples[frame * channels + channel] }
    }

    /// Feeds `frames` frames given one buffer per channel, for the
    /// channels it was made for.
    mutating func add(planar channels: [UnsafePointer<Float>], frames: Int) {
        guard channels.count == filters.count else { return }
        add(frames: frames) { frame, channel in channels[channel][frame] }
    }

    private mutating func add(frames: Int, sample: (Int, Int) -> Float) {
        let channels = filters.count
        for frame in 0..<frames {
            var sum = 0.0
            for channel in 0..<channels {
                let sample = sample(frame, channel)
                peak = max(peak, abs(sample))
                let weighted = Double(filters[channel](sample))
                sum += weighted * weighted
            }
            stepSum += sum * channelWeight
            stepCount += 1
            if stepCount == stepFrames { finishStep() }
        }
    }

    private mutating func finishStep() {
        steps.append(stepSum / Double(stepCount))
        stepSum = 0
        stepCount = 0
        if let momentary = loudness(ofLast: 4) { loudestMomentary = max(loudestMomentary, momentary) }
        if let shortTerm = loudness(ofLast: 30) { loudestShortTerm = max(loudestShortTerm, shortTerm) }
    }

    /// The loudness of the last `count` steps, or nil before there are
    /// that many.
    private func loudness(ofLast count: Int) -> Double? {
        guard steps.count >= count else { return nil }
        return Loudness.lufs(meanSquare: steps.suffix(count).reduce(0, +) / Double(count))
    }

    /// The program's integrated loudness: the mean of its 400 ms blocks
    /// (starting every 100 ms) that are above −70 LUFS, and then of those
    /// within 10 LU of that mean. Silence when nothing passes.
    var integrated: Double {
        guard steps.count >= 4 else { return Loudness.silence }
        let blocks = (0...(steps.count - 4)).map { start in steps[start..<(start + 4)].reduce(0, +) / 4 }
        let absolute = Loudness.meanSquare(lufs: -70)
        let audible = blocks.filter { $0 > absolute }
        guard !audible.isEmpty else { return Loudness.silence }
        let relative = audible.reduce(0, +) / Double(audible.count) * Loudness.meanSquare(lufs: -10) / Loudness.meanSquare(lufs: 0)
        let gated = audible.filter { $0 > relative }
        guard !gated.isEmpty else { return Loudness.silence }
        return Loudness.lufs(meanSquare: gated.reduce(0, +) / Double(gated.count))
    }
}
