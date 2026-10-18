import AVFoundation
import CoreMedia
import Foundation

/// The loudness an export is delivered at: the mix as it is, or gained to
/// a delivery spec's integrated loudness with its peaks held under
/// `LoudnessMastering.ceiling`.
enum LoudnessTarget: String, CaseIterable, Identifiable, Sendable {
    case asMixed
    /// Streaming services: YouTube, Spotify, TikTok.
    case streaming
    /// Apple's and most podcasts' spec.
    case podcast
    /// EBU R128 broadcast.
    case broadcast

    var id: Self { self }

    var lufs: Double? {
        switch self {
        case .asMixed: nil
        case .streaming: -14
        case .podcast: -16
        case .broadcast: -23
        }
    }

    var name: String {
        switch self {
        case .asMixed: "As Mixed"
        case .streaming: "−14 LUFS"
        case .podcast: "−16 LUFS"
        case .broadcast: "−23 LUFS"
        }
    }

    /// What it is for, to follow its name in a sentence.
    var detail: String {
        switch self {
        case .asMixed: "the sound as it is mixed"
        case .streaming: "for streaming services"
        case .podcast: "for podcasts and Apple's spec"
        case .broadcast: "for EBU R128 broadcast"
        }
    }
}

/// Gains an export's sound to a loudness target and holds its peaks under
/// a ceiling. AVFoundation's audio mix has taps on its tracks but none on
/// their sum, so the mix is read out once to measure it and again to render
/// it, gained and limited, to a file whose sound replaces the
/// composition's tracks for the export. See docs/audio.md, "Loudness on
/// export".
enum LoudnessMastering {
    /// Where peaks are held, in dBFS.
    static let ceiling = -1.0
    /// The mix is read at this rate, in stereo.
    static let sampleRate = 48_000.0
    /// The most frames the limiter takes at once.
    private static let chunk = 4096

    /// What mastering did, for a test or a note to the person.
    struct Report: Equatable, Sendable {
        /// The mix's integrated loudness before, in LUFS.
        var measured: Double
        /// The gain applied, in dB.
        var gain: Double
    }

    /// Masters `composed`'s sound to `target` in place: measures it, renders
    /// it into `directory`, and puts the rendered file in place of its audio
    /// tracks. Returns nil, changing nothing, when there is no target, no
    /// sound, or only silence. `progress` goes from 0 to 1 over both reads.
    static func master(
        _ composed: ComposedTimeline, curves: MixCurves, to target: LoudnessTarget, in directory: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> (report: Report, file: URL)? {
        guard let lufs = target.lufs, !composed.audioTracks.isEmpty else { return nil }
        let measurement = try await measure(composed, curves: curves) { progress($0 / 2) }
        guard measurement.integrated.isFinite else { return nil }
        let gain = lufs - measurement.integrated
        let url = directory.appending(path: "mastered-\(UUID().uuidString).caf")
        try await render(composed, curves: curves, gain: gain, to: url) { progress(0.5 + $0 / 2) }
        try await replaceAudio(of: composed.composition, with: url)
        return (Report(measured: measurement.integrated, gain: gain), url)
    }

    /// The loudness of the mix as it plays.
    static func measure(
        _ composed: ComposedTimeline, curves: MixCurves, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> LoudnessMeasurement {
        let reading = try mixReader(composed, curves: curves, interleaved: true)
        let duration = composed.composition.duration.seconds
        return try await SampleReading.run { isCancelled in
            let (reader, output) = reading.value
            guard reader.startReading() else { throw reader.error ?? CompositionError.exportFailed("The sound couldn't be read.") }
            var measurement = LoudnessMeasurement(sampleRate: sampleRate, channels: 2)
            while let buffer = output.copyNextSampleBuffer() {
                if isCancelled() {
                    reader.cancelReading()
                    throw CancellationError()
                }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
                _ = samples.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                samples.withUnsafeBufferPointer { measurement.add(interleaved: $0) }
                if duration > 0 { progress(min(1, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration)) }
            }
            if reader.status == .failed { throw reader.error ?? CompositionError.exportFailed("The sound couldn't be read.") }
            return measurement
        }
    }

    /// Renders the mix to a CAF file at `url`: gained by `gain` dB, then
    /// through a peak limiter that holds it under `ceiling`. The limiter
    /// looks ahead, so its first moments are dropped and its last flushed
    /// out, keeping the sound in step with the picture.
    static func render(
        _ composed: ComposedTimeline, curves: MixCurves, gain: Double, to url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let reading = try mixReader(composed, curves: curves, interleaved: false)
        let duration = composed.composition.duration.seconds
        try await SampleReading.run { isCancelled in
            let (reader, output) = reading.value
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)),
                  let limiter = AudioEffectUnit(effectID: UUID(), kind: .limiter, format: format.streamDescription.pointee, maxFrames: chunk)
            else { throw CompositionError.exportFailed("The sound couldn't be limited.") }
            var settings = Effect(kind: .limiter)
            if let release = settings.controls.firstIndex(where: { $0.kind == .limiterRelease }) {
                // As long as the limiter allows, so held peaks don't pump.
                settings.controls[release].setComponent(0, to: ControlKind.limiterRelease.range!.upperBound, at: .zero)
            }
            limiter.apply(settings, at: .zero)
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            // Into the limiter, which holds peaks at full scale, a little
            // louder than wanted, and out again under the ceiling.
            let into = Float(pow(10, (gain - ceiling) / 20))
            let out = Float(pow(10, ceiling / 20))
            var toSkip = Int((limiter.latency * sampleRate).rounded())
            let latencyFrames = toSkip

            func push(_ frames: Int, fill: (UnsafeMutablePointer<Float>, Int) -> Void) throws {
                let channels = buffer.floatChannelData!
                for channel in 0..<2 {
                    fill(channels[channel], channel)
                    for frame in 0..<frames { channels[channel][frame] *= into }
                }
                buffer.frameLength = AVAudioFrameCount(frames)
                limiter.process(buffer.mutableAudioBufferList, frames: frames)
                let skipped = min(toSkip, frames)
                toSkip -= skipped
                guard frames > skipped else { return }
                for channel in 0..<2 {
                    let data = channels[channel]
                    for frame in skipped..<frames { data[frame - skipped] = data[frame] * out }
                }
                buffer.frameLength = AVAudioFrameCount(frames - skipped)
                try file.write(from: buffer)
            }

            guard reader.startReading() else { throw reader.error ?? CompositionError.exportFailed("The sound couldn't be read.") }
            while let sample = output.copyNextSampleBuffer() {
                if isCancelled() {
                    reader.cancelReading()
                    throw CancellationError()
                }
                // Room for both channels' buffers.
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { list.unsafeMutablePointer.deallocate() }
                var block: CMBlockBuffer?
                let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    sample, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
                    bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2),
                    blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                    flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block
                )
                guard status == noErr, list.count > 0 else { continue }
                let total = CMSampleBufferGetNumSamples(sample)
                var start = 0
                while start < total {
                    let frames = min(chunk, total - start)
                    try push(frames) { destination, channel in
                        let from = list[min(channel, list.count - 1)].mData!.assumingMemoryBound(to: Float.self)
                        destination.update(from: from + start, count: frames)
                    }
                    start += frames
                }
                if duration > 0 { progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)) }
            }
            if reader.status == .failed { throw reader.error ?? CompositionError.exportFailed("The sound couldn't be read.") }
            // What the limiter still holds.
            var flushed = latencyFrames
            while flushed > 0 {
                let frames = min(chunk, flushed)
                try push(frames) { destination, _ in destination.update(repeating: 0, count: frames) }
                flushed -= frames
            }
        }
    }

    /// Takes out the composition's audio tracks and puts the sound of the
    /// file at `url` in their place, from the start.
    static func replaceAudio(of composition: AVMutableComposition, with url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CompositionError.exportFailed("The mastered sound couldn't be read.")
        }
        let length = CMTimeMinimum(try await asset.load(.duration), composition.duration)
        for track in composition.tracks(withMediaType: .audio) { composition.removeTrack(track) }
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositionError.exportFailed("The mastered sound couldn't be added.")
        }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: .zero)
    }

    /// A reader of the whole mix, in stereo float at `sampleRate`.
    private static func mixReader(
        _ composed: ComposedTimeline, curves: MixCurves, interleaved: Bool
    ) throws -> HandedOver<(AVAssetReader, AVAssetReaderAudioMixOutput)> {
        let reader = try AVAssetReader(asset: composed.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: composed.composition.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !interleaved,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ])
        output.audioMix = composed.audioMix(curves: curves)
        reader.add(output)
        return HandedOver(value: (reader, output))
    }
}
