import Accelerate
import AVFoundation
import CoreMedia
import Foundation

/// The sound a Waveform draws (see docs/waveform-effect.md, "Drawing and
/// caching"): each file's samples, read the first time a Waveform hears it
/// and kept for the session, 16-bit at 44.1 kHz in up to two channels
/// (about 32 MB for a three-minute stereo song), and the mix of the clips
/// it hears read from them at any moment.
///
/// The compositor draws a Waveform at once, on its own thread, so a file
/// not read yet is read there and then (a fraction of a second a minute
/// of sound), one reader per file. Building a timeline starts reading the
/// files its Waveforms hear in the background (`prefetch`), so by the
/// time a frame is drawn they are usually there. Drawing never shows a
/// waveform before its sound has been read, so nothing drawn or rendered
/// needs drawing again when it arrives.
final class WaveformAudio: @unchecked Sendable {
    static let shared = WaveformAudio()

    /// A file's samples.
    struct Samples: Sendable {
        static let rate = 44_100.0
        /// Each channel's samples; one channel for a mono file.
        let channels: [[Int16]]

        var count: Int { channels.first?.count ?? 0 }

        /// Channel `channel` (0 left, 1 right; the left again for a mono
        /// file) at sample `index`, -1...1; 0 outside the file.
        @inline(__always)
        func value(_ channel: Int, at index: Int) -> Double {
            guard index >= 0, index < count else { return 0 }
            let samples = channels[min(channel, channels.count - 1)]
            return Double(samples[index]) / 32_768
        }
    }

    private let lock = NSLock()
    private var read: [URL: Samples] = [:]
    /// One lock a file, held while it is read, so it is read once.
    private var reading: [URL: NSLock] = [:]

    /// The samples of the file at `url`, reading it first if need be. Nil
    /// for a file with no sound, or one that can't be read.
    func samples(for url: URL) -> Samples? {
        let fileLock: NSLock = lock.withLock {
            if let lock = reading[url] { return lock }
            let made = NSLock()
            reading[url] = made
            return made
        }
        return fileLock.withLock {
            if let done = lock.withLock({ read[url] }) { return done }
            guard let samples = Self.decode(url) else { return nil }
            lock.withLock { read[url] = samples }
            return samples
        }
    }

    /// Takes `samples` as the file at `url`'s, as if read: for tests.
    func store(_ samples: Samples, for url: URL) {
        lock.withLock { read[url] = samples }
    }

    /// Starts reading `urls` in the background.
    func prefetch(_ urls: [URL]) {
        let missing = lock.withLock { urls.filter { read[$0] == nil } }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for url in missing { _ = self.samples(for: url) }
        }
    }

    /// The file's first sound track as 16-bit samples at `Samples.rate`,
    /// in one or two channels.
    private static func decode(_ url: URL) -> Samples? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
        let sourceChannels = track.formatDescriptions.first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0 as! CMAudioFormatDescription)?.pointee.mChannelsPerFrame } ?? 1
        let channelCount = sourceChannels >= 2 ? 2 : 1
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Samples.rate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var channels = [[Int16]](repeating: [], count: channelCount)
        var chunk: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Int16>.size
            guard count > 0 else { continue }
            if chunk.count != count { chunk = [Int16](repeating: 0, count: count) }
            let status = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for frame in 0..<(count / channelCount) {
                for c in 0..<channelCount { channels[c].append(chunk[frame * channelCount + c]) }
            }
        }
        guard reader.status == .completed, !(channels.first?.isEmpty ?? true) else { return nil }
        return Samples(channels: channels)
    }

    // MARK: The mix

    /// What `sound` plays at each of `times` (seconds of the timeline its
    /// clips are in), in channel `channel` (0 left, 1 right, nil both
    /// mixed), each clip at its volume and its layer's. When a point stands
    /// for more samples than `span` seconds, it is the one of them furthest
    /// from silence, so a long window keeps its peaks.
    func mix(_ sound: WaveformSound, at times: [Double], channel: Int?, span: Double = 0) -> [Double] {
        var mixed = [Double](repeating: 0, count: times.count)
        let reach = max(Int(span * Samples.rate), 1)
        for source in sound.sources {
            guard let samples = samples(for: source.url) else { continue }
            let clip = source.clip
            let start = clip.startOffset.seconds, end = clip.endOffset.seconds
            for (k, time) in times.enumerated() where time >= start && time < end {
                let timelineTime = CMTime(seconds: time, preferredTimescale: 96_000)
                let sourceTime = clip.sourceTime(atTimelineTime: timelineTime)
                var decibels = clip.volume.value(at: sourceTime)
                if let layer = source.layerVolume { decibels += layer.value(at: timelineTime) }
                guard decibels > AudioLevel.silence else { continue }
                let gain = pow(10, decibels / 20)
                let index = Int((source.asset.fileTime(forSourceTime: sourceTime).seconds * Samples.rate).rounded())
                func value(at i: Int) -> Double {
                    guard let channel else { return (samples.value(0, at: i) + samples.value(1, at: i)) / 2 }
                    return samples.value(channel, at: i)
                }
                if reach > 1 {
                    var peak = 0.0
                    for i in index..<(index + reach) {
                        let v = value(at: i)
                        if abs(v) > abs(peak) { peak = v }
                    }
                    mixed[k] += peak * gain
                } else {
                    mixed[k] += value(at: index) * gain
                }
            }
        }
        return mixed
    }

    // MARK: The spectrum

    /// Samples looked at for a spectrum: about a tenth of a second, enough
    /// to tell 20 Hz from 30.
    static let spectrumLength = 4096
    /// Only ever used to transform, which doesn't change it.
    nonisolated(unsafe) private static let spectrumSetup = vDSP.FFT(log2n: vDSP_Length(12), radix: .radix2, ofType: DSPSplitComplex.self)
    private static let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: spectrumLength, isHalfWindow: false)
    /// The quietest level a spectrum shows, in decibels.
    static let floor = -80.0

    /// How loud `sound` is at `bands` frequencies (hertz) around `time`
    /// (seconds of its clips' timeline), in channel `channel` (nil both),
    /// each 0 (at `floor` or below) to 1 (full scale) and more for louder,
    /// before any gain.
    func spectrum(_ sound: WaveformSound, at time: Double, bands: [Double], channel: Int?) -> [Double] {
        let n = Self.spectrumLength
        let times = (0..<n).map { time + (Double($0) - Double(n / 2)) / Samples.rate }
        let wave = mix(sound, at: times, channel: channel).map { Float($0) }
        guard let fft = Self.spectrumSetup, wave.contains(where: { $0 != 0 }) else { return bands.map { _ in 0 } }
        let windowed = vDSP.multiply(wave, Self.window)
        var real = [Float](repeating: 0, count: n / 2), imaginary = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                let input = split
                fft.forward(input: input, output: &split)
                vDSP.absolute(split, result: &magnitudes)
            }
        }
        // A full-scale sine through a Hann window comes out at n / 2 times
        // half its amplitude, doubled by the packed transform.
        let fullScale = Double(n) / 2
        let binWidth = Samples.rate / Double(n)
        return bands.map { frequency in
            let bin = (frequency / binWidth).clamped(between: 1, and: Double(n / 2 - 2))
            let low = Int(bin), fraction = bin - Double(low)
            let magnitude = Double(magnitudes[low]) * (1 - fraction) + Double(magnitudes[low + 1]) * fraction
            let decibels = 20 * log10(max(magnitude / fullScale, 1e-9))
            return max((decibels - Self.floor) / -Self.floor, 0)
        }
    }
}
