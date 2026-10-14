import AVFoundation
import CoreMedia
import Foundation
import Observation

/// A coarse picture of a file's sound for drawing on clips: the loudest
/// sample in each short window, scaled so the file's loudest moment is 1.
/// Coarse on purpose: a clip is at most a few thousand points wide, and the
/// whole envelope of a long song stays small enough to keep in memory.
struct Waveform: Sendable, Equatable {
    /// Windows per second of the file.
    static let peaksPerSecond = 200.0

    /// One per window, 0...1, from the start of the file.
    let peaks: [Float]

    /// The loudest window between two file times, in seconds, or 0 where
    /// the file has no sound.
    func peak(from start: Double, to end: Double) -> Float {
        let first = max(0, Int((start * Self.peaksPerSecond).rounded(.down)))
        let last = min(peaks.count, max(first + 1, Int((end * Self.peaksPerSecond).rounded(.up))))
        guard first < last else { return 0 }
        return peaks[first..<last].max() ?? 0
    }

    /// The envelope of mono samples at `sampleRate`, normalized to the
    /// loudest window.
    static func envelope(of samples: [Float], sampleRate: Double) -> Waveform {
        let window = max(1, Int(sampleRate / peaksPerSecond))
        var peaks: [Float] = []
        peaks.reserveCapacity(samples.count / window + 1)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + window)
            var loudest: Float = 0
            for sample in samples[index..<end] { loudest = max(loudest, abs(sample)) }
            peaks.append(loudest)
            index = end
        }
        let top = peaks.max() ?? 0
        return Waveform(peaks: top > 0 ? peaks.map { $0 / top } : peaks)
    }

    /// Reads the first audio track of a file. Cancelling stops the read.
    static func read(url: URL) async throws -> Waveform {
        let sampleRate = 8_000.0
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return Waveform(peaks: []) }
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
            guard reader.canAdd(output) else { return Waveform(peaks: []) }
            reader.add(output)
            guard reader.startReading() else { return Waveform(peaks: []) }
            var samples: [Float] = []
            while let buffer = output.copyNextSampleBuffer() {
                if isCancelled() {
                    reader.cancelReading()
                    throw CancellationError()
                }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                let status = chunk.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                if status == kCMBlockBufferNoErr { samples.append(contentsOf: chunk) }
            }
            return envelope(of: samples, sampleRate: sampleRate)
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
