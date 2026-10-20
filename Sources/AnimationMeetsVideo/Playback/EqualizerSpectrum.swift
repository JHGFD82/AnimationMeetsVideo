import Accelerate
import AVFoundation
import Foundation
import os

/// The sound going into and out of each EQ whose graph is showing, for the
/// spectrum behind its curves (see docs/equalizer.md, "The graph").
///
/// A tap's filter records each buffer, summed to mono, before and after
/// the EQ, stamped with the clip's source time it plays at. Players decode
/// ahead of what is heard, so the graph doesn't read the newest samples:
/// it reads the 4096 that end at the playhead's source time, and gets
/// nothing for a moment the taps haven't played (paused, or scrubbed away).
/// Only EQs being watched record, so the taps of everything else, and
/// exports, don't pay for it.
final class EqualizerSpectrum: @unchecked Sendable {
    static let shared = EqualizerSpectrum()

    /// Samples per analysis, about 85 ms at 48 kHz.
    static let windowSize = 4096
    private static let log2n = vDSP_Length(12)
    /// Samples kept per EQ: about 1.4 seconds at 48 kHz.
    private static let capacity = 65_536
    private static let anchorCount = 128

    /// Where one recorded buffer is: its first sample's place in the
    /// recording, how many there are, and the source time they span.
    private struct Anchor {
        var index: Int
        var count: Int
        var start: Double
        var end: Double
    }

    private struct Recording {
        var pre = [Float](repeating: 0, count: EqualizerSpectrum.capacity)
        var post = [Float](repeating: 0, count: EqualizerSpectrum.capacity)
        /// How many samples have been recorded in all.
        var written = 0
        var anchors: [Anchor] = []
        var sampleRate = 48_000.0
    }

    private struct State {
        /// How many graphs watch each EQ.
        var watchers: [UUID: Int] = [:]
        var recordings: [UUID: Recording] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let fft = vDSP_create_fftsetup(EqualizerSpectrum.log2n, FFTRadix(kFFTRadix2))!
    /// A Hann window peaking at 1 (`HANN_NORM` peaks higher, which would
    /// read 4 dB loud).
    private let window: [Float] = {
        var hann = [Float](repeating: 0, count: EqualizerSpectrum.windowSize)
        vDSP_hann_window(&hann, vDSP_Length(EqualizerSpectrum.windowSize), Int32(vDSP_HANN_DENORM))
        return hann
    }()

    // MARK: Watching

    func watch(_ effectID: UUID) {
        state.withLock { $0.watchers[effectID, default: 0] += 1 }
    }

    func unwatch(_ effectID: UUID) {
        state.withLock { state in
            let left = (state.watchers[effectID] ?? 1) - 1
            if left > 0 {
                state.watchers[effectID] = left
            } else {
                state.watchers[effectID] = nil
                state.recordings[effectID] = nil
            }
        }
    }

    func isWatched(_ effectID: UUID) -> Bool {
        state.withLock { $0.watchers[effectID] != nil }
    }

    // MARK: Recording

    /// Records one buffer of `frames` mono samples played from source time
    /// `start` to `end` (seconds), before and after the EQ. Only the tap's
    /// thread calls it, and only for a watched EQ.
    func record(_ effectID: UUID, pre: UnsafePointer<Float>, post: UnsafePointer<Float>, frames: Int, start: Double, end: Double, sampleRate: Double) {
        guard frames > 0 else { return }
        // Unchecked: it copies from the tap's buffers, which stay put for
        // the length of the call.
        state.withLockUnchecked { state in
            guard state.watchers[effectID] != nil else { return }
            var recording = state.recordings[effectID] ?? Recording()
            state.recordings[effectID] = nil
            if recording.sampleRate != sampleRate {
                recording = Recording()
                recording.sampleRate = sampleRate
            }
            let capacity = Self.capacity
            for offset in 0..<min(frames, capacity) {
                let at = (recording.written + offset) % capacity
                recording.pre[at] = pre[offset]
                recording.post[at] = post[offset]
            }
            recording.anchors.append(Anchor(index: recording.written, count: frames, start: start, end: end))
            if recording.anchors.count > Self.anchorCount { recording.anchors.removeFirst(recording.anchors.count - Self.anchorCount) }
            recording.written += frames
            state.recordings[effectID] = recording
        }
    }

    // MARK: Reading

    /// The level of each frequency, in dBFS, of the sound before
    /// (`pre`) or after the EQ in the window ending at source time `time`,
    /// with the frequency each value is at. Nil when nothing recorded
    /// covers that moment.
    func levels(of effectID: UUID, pre: Bool, at time: Double) -> (decibels: [Float], binWidth: Double)? {
        let size = Self.windowSize
        var frame = [Float](repeating: 0, count: size)
        let found: Double? = state.withLockUnchecked { state in
            guard let recording = state.recordings[effectID],
                  let anchor = recording.anchors.last(where: { $0.start <= time && time <= $0.end && $0.end > $0.start })
            else { return nil }
            let end = anchor.index + Int((time - anchor.start) / (anchor.end - anchor.start) * Double(anchor.count))
            let oldest = recording.written - Self.capacity
            guard end - size >= max(0, oldest), end <= recording.written else { return nil }
            let samples = pre ? recording.pre : recording.post
            for offset in 0..<size { frame[offset] = samples[(end - size + offset) % Self.capacity] }
            return recording.sampleRate
        }
        guard let sampleRate = found else { return nil }
        return (decibels(of: frame), sampleRate / Double(size))
    }

    /// Each bin's level of a windowed FFT of `frame`, in dBFS: a full-scale
    /// sine reads about 0 dB in its bin.
    fileprivate func decibels(of input: [Float]) -> [Float] {
        let size = Self.windowSize, bins = size / 2
        var frame = [Float](repeating: 0, count: size)
        vDSP_vmul(input, 1, window, 1, &frame, 1, vDSP_Length(size))
        var real = [Float](repeating: 0, count: bins)
        var imaginary = [Float](repeating: 0, count: bins)
        var magnitudes = [Float](repeating: 0, count: bins)
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                frame.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
                // The packed Nyquist value isn't a level of its own.
                imaginary[0] = 0
                magnitudes.withUnsafeMutableBufferPointer { output in
                    vDSP_zvabs(&split, 1, output.baseAddress!, 1, vDSP_Length(bins))
                }
            }
        }
        // zrip doubles, and a Hann window halves, a sine's N/2.
        let fullScale = Float(size) / 2
        return magnitudes.map { 20 * log10(max($0 / fullScale, 1e-6)) }
    }
}

// MARK: - From the file

extension EqualizerSpectrum {
    /// The spectrum of a media file's sound in the window ending at
    /// `fileTime`, read from the file itself, for a graph while nothing is
    /// playing. After the EQ (`pre` false) it is run through `effect` as set
    /// at `effectTime`, in the clip's source time. Effects above the EQ in
    /// the sound's stack, and the clip's volume, aren't applied. Nil when
    /// the file has no sound there or can't be read.
    static func levels(
        ofFile url: URL, endingAt fileTime: CMTime, through effect: Effect, at effectTime: CMTime, pre: Bool
    ) async -> (decibels: [Float], binWidth: Double)? {
        let sampleRate = 48_000.0
        // A little more than a window, so the filters settle first.
        let span = 0.25
        let start = max(0, fileTime.seconds - span)
        guard fileTime.seconds - start >= Double(windowSize) / sampleRate else { return nil }
        let asset = MediaFile.asset(at: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let handed = HandedOver(value: (asset, track))
        let samples: [Float]? = try? await SampleReading.run { isCancelled in
            let (asset, track) = handed.value
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 48_000),
                end: CMTime(seconds: fileTime.seconds, preferredTimescale: 48_000)
            )
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1, AVSampleRateKey: sampleRate,
            ])
            reader.add(output)
            guard reader.startReading() else { return nil }
            var samples: [Float] = []
            while !isCancelled(), let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var chunk = [Float](repeating: 0, count: length / 4)
                chunk.withUnsafeMutableBytes { bytes in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
                }
                samples += chunk
            }
            if isCancelled() { throw CancellationError() }
            return samples
        }
        guard var samples, samples.count >= windowSize else { return nil }
        if !pre {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let filter = EqualizerFilter(effectID: effect.id, format: format.streamDescription.pointee, maxFrames: samples.count),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0]
            else { return nil }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            filter.apply(effect, from: effectTime, to: effectTime)
            filter.process(buffer.mutableAudioBufferList, frames: samples.count)
            samples = Array(UnsafeBufferPointer(start: channel, count: samples.count))
        }
        return (shared.decibels(of: Array(samples.suffix(windowSize))), sampleRate / Double(windowSize))
    }
}

/// A spectrum as a graph shows it: rising at once and falling back at the
/// meter's rate, so it is readable while it moves.
final class SpectrumBallistics {
    private(set) var decibels: [Float] = []
    private(set) var binWidth = 0.0
    private var lastUpdate: Double?

    /// The floor of the spectrum's scale.
    static let floor: Float = -90

    /// Moves to `now` (seconds) with a new reading, or with none.
    func update(_ reading: (decibels: [Float], binWidth: Double)?, now: Double) {
        let elapsed = lastUpdate.map { max(0, now - $0) } ?? 0
        lastUpdate = now
        let fall = Float(MeterBallistics.fallRate * elapsed)
        guard let reading else {
            decibels = decibels.map { max(Self.floor, $0 - fall) }
            if decibels.allSatisfy({ $0 <= Self.floor }) { decibels = [] }
            return
        }
        if decibels.count != reading.decibels.count {
            decibels = reading.decibels
        } else {
            for index in decibels.indices { decibels[index] = max(reading.decibels[index], decibels[index] - fall) }
        }
        binWidth = reading.binWidth
    }
}
