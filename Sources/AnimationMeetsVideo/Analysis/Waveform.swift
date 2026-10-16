import AVFoundation
import CoreMedia
import Foundation
import Observation

/// A coarse picture of a file's sound for drawing on clips: the loudest
/// sample in each short window, scaled so the file's loudest moment is 1.
/// Coarse on purpose: a clip is at most a few thousand points wide, and the
/// whole envelope of a long song stays small enough to keep in memory.
///
/// Kept per channel (left and right for stereo; files with more channels
/// are read mixed down to two), so a layer can show its channels apart.
struct Waveform: Sendable, Equatable {
    /// Windows per second of the file.
    static let peaksPerSecond = 200.0

    /// One per window, 0...1, from the start of the file: the loudest of
    /// any channel.
    let peaks: [Float]
    /// The same for each channel on its own, all scaled together so the
    /// loudest channel's loudest window is 1.
    let channels: [[Float]]

    init(peaks: [Float]) {
        self.peaks = peaks
        channels = peaks.isEmpty ? [] : [peaks]
    }

    init(channels: [[Float]]) {
        self.channels = channels
        let count = channels.map(\.count).max() ?? 0
        peaks = (0..<count).map { index in
            channels.reduce(Float(0)) { max($0, index < $1.count ? $1[index] : 0) }
        }
    }

    /// The loudest window between two file times, in seconds, of one
    /// channel or (nil) of any; 0 where the file has no sound.
    func peak(from start: Double, to end: Double, channel: Int? = nil) -> Float {
        let values = channel.map { channels.indices.contains($0) ? channels[$0] : [] } ?? peaks
        let first = max(0, Int((start * Self.peaksPerSecond).rounded(.down)))
        let last = min(values.count, max(first + 1, Int((end * Self.peaksPerSecond).rounded(.up))))
        guard first < last else { return 0 }
        return values[first..<last].max() ?? 0
    }

    /// The envelope of mono samples at `sampleRate`, normalized to the
    /// loudest window.
    static func envelope(of samples: [Float], sampleRate: Double) -> Waveform {
        envelope(ofInterleaved: samples, channelCount: 1, sampleRate: sampleRate)
    }

    /// The envelope of each channel of interleaved samples, normalized
    /// together to the loudest window of any channel.
    static func envelope(ofInterleaved samples: [Float], channelCount: Int, sampleRate: Double) -> Waveform {
        var collector = PeakCollector(channelCount: channelCount, sampleRate: sampleRate)
        samples.withUnsafeBufferPointer { collector.add(interleaved: $0) }
        return collector.waveform()
    }

    /// Collects each channel's loudest sample in every window as samples
    /// arrive, so a long file's sound is never held whole: only the peaks
    /// are kept.
    struct PeakCollector {
        let channelCount: Int
        let window: Int
        private var channels: [[Float]]
        private var loudest: [Float]
        /// Frames in the window being collected.
        private var filled = 0

        init(channelCount: Int, sampleRate: Double) {
            self.channelCount = max(1, channelCount)
            window = max(1, Int(sampleRate / Waveform.peaksPerSecond))
            channels = [[Float]](repeating: [], count: self.channelCount)
            loudest = [Float](repeating: 0, count: self.channelCount)
        }

        /// Takes whole frames of interleaved samples; a partial frame at the
        /// end is ignored.
        mutating func add(interleaved samples: UnsafeBufferPointer<Float>) {
            let frames = samples.count / channelCount
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    loudest[channel] = max(loudest[channel], abs(samples[frame * channelCount + channel]))
                }
                filled += 1
                if filled == window { closeWindow() }
            }
        }

        private mutating func closeWindow() {
            for channel in 0..<channelCount {
                channels[channel].append(loudest[channel])
                loudest[channel] = 0
            }
            filled = 0
        }

        /// Everything collected, the last part-filled window included,
        /// normalized together to the loudest window of any channel.
        func waveform() -> Waveform {
            var collector = self
            if collector.filled > 0 { collector.closeWindow() }
            let top = collector.channels.flatMap { $0 }.max() ?? 0
            return Waveform(channels: top > 0 ? collector.channels.map { $0.map { $0 / top } } : collector.channels)
        }
    }

    /// Reads the first audio track of a file. Cancelling stops the read.
    static func read(url: URL) async throws -> Waveform {
        let sampleRate = 8_000.0
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return Waveform(peaks: []) }
        // Two channels at most: more need a channel layout to be read, and
        // the timeline only tells left from right.
        let sourceChannels = try await track.load(.formatDescriptions).first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        let channelCount = sourceChannels >= 2 ? 2 : 1
        let handedOver = HandedOver(value: track)
        return try await SampleReading.run { isCancelled in
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: handedOver.value, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return Waveform(peaks: []) }
            reader.add(output)
            guard reader.startReading() else { return Waveform(peaks: []) }
            var collector = PeakCollector(channelCount: channelCount, sampleRate: sampleRate)
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
                if status == kCMBlockBufferNoErr { chunk.withUnsafeBufferPointer { collector.add(interleaved: $0) } }
            }
            return collector.waveform()
        }
    }
}

/// Waveforms by file, read the first time a clip asks to draw one and kept
/// for the rest of the session. Views that read `waveform(for:)` redraw
/// when it arrives.
@MainActor @Observable
final class WaveformCache {
    static let shared = WaveformCache()

    private var waveforms: [URL: Waveform] = [:]
    @ObservationIgnored private var loading: Set<URL> = []

    /// The file's waveform, or nil while it is being read (the read starts
    /// on the first ask).
    func waveform(for url: URL) -> Waveform? {
        if let waveform = waveforms[url] { return waveform }
        if !loading.contains(url) {
            loading.insert(url)
            Task {
                let waveform = (try? await Waveform.read(url: url)) ?? Waveform(peaks: [])
                waveforms[url] = waveform
                loading.remove(url)
            }
        }
        return nil
    }

    /// Forgets every waveform, for when a file was swapped under the same
    /// path.
    func invalidateAll() {
        waveforms.removeAll()
    }
}
