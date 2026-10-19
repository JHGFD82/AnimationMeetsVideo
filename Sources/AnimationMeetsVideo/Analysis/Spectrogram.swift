import AVFoundation
import Accelerate
import CoreMedia
import Foundation

/// How loud each of 48 frequency bands of a file's sound is, 50 times a
/// second, for Audio Keys (see docs/keyframing-effects.md, "Analysis").
/// Bands are log-spaced from 20 Hz to 20 kHz; each level is the band's
/// power (its mean square, so a full-scale sine reads about −3 dB) in
/// half-decibel steps from −128 dB, one byte each: 2.4 KB a second of
/// sound.
struct Spectrogram: Sendable, Equatable {
    static let bandCount = 48
    static let framesPerSecond = 50.0
    static let lowestFrequency = 20.0
    static let highestFrequency = 20_000.0
    static let floor = -128.0
    static let fftSize = 4096
    /// What files are read at, so the top band (up to 20 kHz) has bins.
    static let sampleRate = 44_100.0

    /// `bandCount` per frame, frame after frame from the start of the file.
    let levels: [UInt8]
    /// A fingerprint of the levels, so an Audio Keys effect sees a file
    /// that changed under it.
    let fingerprint: UInt64

    init(levels: [UInt8]) {
        self.levels = levels
        var print = KeyframingPrint()
        for byte in levels { print.add(UInt64(byte)) }
        fingerprint = print.value
    }

    var frameCount: Int { levels.count / Self.bandCount }

    /// The edges of band `index`: `index` and `index + 1` of
    /// `bandCount + 1` log-spaced from the lowest frequency to the highest.
    static func edge(_ index: Int) -> Double {
        lowestFrequency * pow(highestFrequency / lowestFrequency, Double(index) / Double(bandCount))
    }

    /// The middle of band `index`, on a log scale.
    static func center(_ index: Int) -> Double {
        sqrt(edge(index) * edge(index + 1))
    }

    /// Band `band`'s level in decibels in frame `frame`, or the floor
    /// outside the file.
    func decibels(frame: Int, band: Int) -> Double {
        guard frame >= 0, frame < frameCount else { return Self.floor }
        return Self.floor + Double(levels[frame * Self.bandCount + band]) / 2
    }

    /// Every band's level at `seconds` of the file, from the nearest frame.
    func decibels(atSeconds seconds: Double) -> [Double] {
        let frame = Int((seconds * Self.framesPerSecond).rounded())
        return (0..<Self.bandCount).map { decibels(frame: frame, band: $0) }
    }

    static func byte(decibels: Double) -> UInt8 {
        UInt8(min(max(((decibels - floor) * 2).rounded(), 0), 255))
    }

    /// The spectrogram of mono samples at `sampleRate`.
    static func analyze(_ samples: [Float], sampleRate: Double = sampleRate) -> Spectrogram {
        var collector = Collector(sampleRate: sampleRate)
        samples.withUnsafeBufferPointer { collector.add($0) }
        return collector.spectrogram()
    }

    /// Turns mono samples into frames as they arrive, keeping only the
    /// samples the next frame's window still needs.
    struct Collector {
        let sampleRate: Double
        private let hop: Double
        private let window: [Float]
        private let windowPower: Float
        /// For each bin, the bands it falls in and how much of it each has.
        private let binBands: [[(band: Int, share: Float)]]
        private let fft: vDSP.FFT<DSPSplitComplex>
        /// Samples from `pendingStart` on.
        private var pending: [Float] = []
        private var pendingStart = 0
        private var samplesSeen = 0
        private var nextFrame = 0
        private var levels: [UInt8] = []

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
            hop = sampleRate / Spectrogram.framesPerSecond
            let n = Spectrogram.fftSize
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
            windowPower = vDSP.sum(vDSP.multiply(window, window))
            fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(n))), radix: .radix2, ofType: DSPSplitComplex.self)!
            let width = sampleRate / Double(n)
            binBands = (0..<(n / 2)).map { bin in
                guard bin > 0 else { return [] }
                let low = (Double(bin) - 0.5) * width, high = (Double(bin) + 0.5) * width
                return (0..<Spectrogram.bandCount).compactMap { band in
                    let overlap = min(high, Spectrogram.edge(band + 1)) - max(low, Spectrogram.edge(band))
                    return overlap > 0 ? (band, Float(overlap / width)) : nil
                }
            }
        }

        /// Where frame `index`'s window starts: it is centered on the
        /// frame's time.
        private func windowStart(_ index: Int) -> Int {
            Int((Double(index) * hop).rounded()) - Spectrogram.fftSize / 2
        }

        mutating func add(_ samples: UnsafeBufferPointer<Float>) {
            pending.append(contentsOf: samples)
            samplesSeen += samples.count
            while windowStart(nextFrame) + Spectrogram.fftSize <= samplesSeen {
                closeFrame()
            }
        }

        private mutating func closeFrame() {
            let n = Spectrogram.fftSize
            let start = windowStart(nextFrame)
            var frame = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let index = start + i - pendingStart
                if index >= 0, index < pending.count { frame[i] = pending[index] * window[i] }
            }
            var real = [Float](repeating: 0, count: n / 2)
            var imaginary = [Float](repeating: 0, count: n / 2)
            var bands = [Float](repeating: 0, count: Spectrogram.bandCount)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    frame.withUnsafeBytes { bytes in
                        vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                    }
                    fft.forward(input: split, output: &split)
                    // vDSP's real transform is twice the DFT, so a bin's
                    // power over the window's is 2|Z|² / (4 · N · Σw²)
                    // counting both halves of the spectrum.
                    let scale = 1 / (2 * Float(n) * windowPower)
                    for bin in 1..<(n / 2) {
                        let power = (realPointer[bin] * realPointer[bin] + imaginaryPointer[bin] * imaginaryPointer[bin]) * scale
                        for (band, share) in binBands[bin] { bands[band] += power * share }
                    }
                }
            }
            for power in bands {
                levels.append(Spectrogram.byte(decibels: 10 * log10(max(Double(power), 1e-20))))
            }
            nextFrame += 1
            // Drop what no later window reaches.
            let keepFrom = windowStart(nextFrame)
            if keepFrom > pendingStart {
                pending.removeFirst(min(keepFrom - pendingStart, pending.count))
                pendingStart = keepFrom
            }
        }

        /// Everything collected, with frames up to the end of the sound
        /// (their windows padded with silence).
        func spectrogram() -> Spectrogram {
            var collector = self
            let last = Int((Double(samplesSeen) / hop).rounded(.down))
            while collector.nextFrame <= last { collector.closeFrame() }
            return Spectrogram(levels: collector.levels)
        }
    }

    /// Reads the first audio track of a file, mixed to mono. Cancelling
    /// stops the read.
    static func read(url: URL) async throws -> Spectrogram {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return Spectrogram(levels: []) }
        let handedOver = HandedOver(value: track)
        return try await SampleReading.run { isCancelled in
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: handedOver.value, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return Spectrogram(levels: []) }
            reader.add(output)
            guard reader.startReading() else { return Spectrogram(levels: []) }
            var collector = Collector(sampleRate: sampleRate)
            var chunk: [Float] = []
            while let buffer = output.copyNextSampleBuffer() {
                if isCancelled() {
                    reader.cancelReading()
                    throw CancellationError()
                }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                if chunk.count != count { chunk = [Float](repeating: 0, count: count) }
                let status = chunk.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                if status == kCMBlockBufferNoErr { chunk.withUnsafeBufferPointer { collector.add($0) } }
            }
            return collector.spectrogram()
        }
    }
}

extension Notification.Name {
    /// A file's spectrogram finished reading, so Audio Keys effects that
    /// listen to it can make their keyframes.
    static let spectrogramsChanged = Notification.Name("AnimationMeetsVideo.spectrogramsChanged")
}

/// Spectrograms by file, read the first time an Audio Keys effect asks and
/// kept for the session, like waveforms: they take a fraction of a second
/// a minute of sound to make again. Read from the model while it makes
/// keyframes, so it is locked rather than tied to the main actor.
final class SpectrogramStore: @unchecked Sendable {
    static let shared = SpectrogramStore()

    private let lock = NSLock()
    private var spectrograms: [URL: Spectrogram] = [:]
    private var loading: Set<URL> = []

    /// The file's spectrogram, or nil while it is being read (the read
    /// starts on the first ask). One that couldn't be read is empty.
    func spectrogram(for url: URL) -> Spectrogram? {
        let (found, start) = lock.withLock { () -> (Spectrogram?, Bool) in
            if let spectrogram = spectrograms[url] { return (spectrogram, false) }
            return (nil, loading.insert(url).inserted)
        }
        if start {
            Task.detached(priority: .utility) {
                let made = (try? await Spectrogram.read(url: url)) ?? Spectrogram(levels: [])
                self.set(made, for: url)
            }
        }
        return found
    }

    /// Stores a spectrogram and tells the editor.
    func set(_ spectrogram: Spectrogram, for url: URL) {
        lock.withLock {
            spectrograms[url] = spectrogram
            loading.remove(url)
        }
        Task { @MainActor in NotificationCenter.default.post(name: .spectrogramsChanged, object: nil) }
    }

    /// Forgets every spectrogram, for when a file was swapped under the
    /// same path.
    func invalidateAll() {
        lock.withLock { spectrograms.removeAll() }
    }
}
