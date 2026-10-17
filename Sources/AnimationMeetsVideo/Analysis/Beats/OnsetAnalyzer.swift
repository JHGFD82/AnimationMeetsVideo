import Accelerate
import Foundation

/// Turns audio into a curve of how much new sound starts at each moment
/// (spectral flux: the growth of each frequency's loudness from one short
/// frame to the next). It takes samples as they are decoded, so a long file
/// is never held in memory.
final class OnsetAnalyzer {
    static let windowSize = 1024
    static let hopSize = 256
    static var framesPerSecond: Double { BeatDetector.sampleRate / Double(hopSize) }

    /// The sample a frame is centered on, counted from the start of the audio.
    static func centerSample(ofFrame frame: Int) -> Int64 {
        Int64(frame * hopSize + windowSize / 2)
    }

    /// Samples from one frame to the next. Detection uses `hopSize`; beat
    /// matching uses a smaller hop, for beats placed within a few
    /// milliseconds.
    let hop: Int
    var framesPerSecond: Double { BeatDetector.sampleRate / Double(hop) }

    private(set) var envelope: [Float] = []

    private let log2n = vDSP_Length(10)
    private let fft: FFTSetup
    private let window: [Float]
    private var pending: [Float] = []
    private var previous: [Float]
    private var hasPrevious = false

    private var frame: [Float]
    private var realPart: [Float]
    private var imaginaryPart: [Float]
    private var magnitudes: [Float]
    private var scaled: [Float]
    private var compressed: [Float]

    init(hop: Int = OnsetAnalyzer.hopSize) {
        precondition(hop > 0 && hop <= Self.windowSize)
        self.hop = hop
        let bins = Self.windowSize / 2
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var hann = [Float](repeating: 0, count: Self.windowSize)
        vDSP_hann_window(&hann, vDSP_Length(Self.windowSize), Int32(vDSP_HANN_NORM))
        window = hann
        previous = [Float](repeating: 0, count: bins)
        frame = [Float](repeating: 0, count: Self.windowSize)
        realPart = [Float](repeating: 0, count: bins)
        imaginaryPart = [Float](repeating: 0, count: bins)
        magnitudes = [Float](repeating: 0, count: bins)
        scaled = [Float](repeating: 0, count: bins)
        compressed = [Float](repeating: 0, count: bins)
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        pending.append(contentsOf: samples)
        var start = 0
        while pending.count - start >= Self.windowSize {
            processFrame(startingAt: start)
            start += hop
        }
        pending.removeFirst(start)
    }

    private func processFrame(startingAt start: Int) {
        let bins = Self.windowSize / 2
        pending.withUnsafeBufferPointer { samples in
            vDSP_vmul(samples.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(Self.windowSize))
        }
        computeMagnitudes()

        // Log compression so a quiet hi-hat counts as much as a loud kick.
        var scale = 1000 / Float(Self.windowSize)
        vDSP_vsmul(magnitudes, 1, &scale, &scaled, 1, vDSP_Length(bins))
        var count = Int32(bins)
        vvlog1pf(&compressed, scaled, &count)

        var flux: Float = 0
        if hasPrevious {
            for bin in 1..<bins {
                flux += max(0, compressed[bin] - previous[bin])
            }
        }
        envelope.append(flux)
        hasPrevious = true
        swap(&previous, &compressed)
    }

    /// The magnitude of every frequency bin of `frame` into `magnitudes`,
    /// indexed by bin, with DC (index 0) left at zero and Nyquist left out.
    ///
    /// `vDSP_fft_zrip` packs its output: `realp[0]` is the DC bin and
    /// `imagp[0]` is the Nyquist bin, two real values from different
    /// frequencies rather than one complex bin. Neither says anything about
    /// where a note starts (DC is offset, Nyquist is above anything the
    /// downsampled audio holds), so they are left out of the flux rather
    /// than mixed into one meaningless magnitude.
    private func computeMagnitudes() {
        let bins = Self.windowSize / 2
        realPart.withUnsafeMutableBufferPointer { real in
            imaginaryPart.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                frame.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                var interior = DSPSplitComplex(realp: real.baseAddress! + 1, imagp: imaginary.baseAddress! + 1)
                magnitudes.withUnsafeMutableBufferPointer { output in
                    vDSP_zvabs(&interior, 1, output.baseAddress! + 1, 1, vDSP_Length(bins - 1))
                    output[0] = 0
                }
            }
        }
    }

    /// The bin magnitudes `computeMagnitudes` gives for one unwindowed
    /// frame of `windowSize` samples, for tests.
    func magnitudes(ofFrame samples: [Float]) -> [Float] {
        precondition(samples.count == Self.windowSize)
        frame = samples
        computeMagnitudes()
        return magnitudes
    }
}
