import AVFoundation
import CoreMedia
import Foundation

enum BeatDetector {
    /// Audio is analyzed as mono at this rate; beats need nothing above it.
    static let sampleRate = 22_050.0

    enum DetectionError: LocalizedError {
        case noAudioTrack
        /// `underlying` is what the reader reported, kept so the cause can be told apart.
        case readerFailed(String, underlying: (any Error)? = nil)
        /// A decoded buffer isn't the PCM asked for, or its samples can't be
        /// read; says what was wrong.
        case malformedAudio(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "The file has no audio track to analyze."
            case .readerFailed(let reason, _): "Couldn't read the audio: \(reason)"
            case .malformedAudio(let reason): "The decoded audio is damaged: \(reason)."
            }
        }
    }

    /// The samples of one buffer from the reader, which was asked for mono
    /// 32-bit float PCM at `sampleRate`. Empty for a buffer that holds no
    /// samples and no data, which the reader may legitimately hand out.
    /// Throws `malformedAudio` for anything else that isn't exactly that
    /// format, or whose data is missing, the wrong size or can't be copied,
    /// rather than skipping it: a skipped buffer shifts every later beat,
    /// and a file read that way would be saved as analyzed.
    static func pcmSamples(of buffer: CMSampleBuffer, sampleRate expected: Double = sampleRate) throws -> [Float] {
        let count = CMSampleBufferGetNumSamples(buffer)
        let block = CMSampleBufferGetDataBuffer(buffer)
        let length = block.map { CMBlockBufferGetDataLength($0) } ?? 0
        guard count > 0 else {
            guard length == 0 else { throw DetectionError.malformedAudio("a buffer has data but no samples") }
            return []
        }
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              description.mChannelsPerFrame == 1, description.mBitsPerChannel == 32,
              description.mBytesPerFrame == UInt32(MemoryLayout<Float>.size),
              description.mSampleRate == expected
        else {
            throw DetectionError.malformedAudio("a buffer isn't mono 32-bit float PCM at \(Int(expected)) Hz")
        }
        guard let block else { throw DetectionError.malformedAudio("a buffer with samples has no data") }
        let (expected, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !overflow, length == expected else {
            throw DetectionError.malformedAudio("a buffer holds \(length) bytes for \(count) samples")
        }
        var samples = [Float](repeating: 0, count: count)
        let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let destination = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: destination)
        }
        guard status == kCMBlockBufferNoErr else {
            throw DetectionError.malformedAudio("a buffer's samples couldn't be copied (error \(status))")
        }
        return samples
    }

    /// Finds the beats of the first audio track. `progress` receives 0...1,
    /// never decreasing, and may be called from a background thread; 1 comes
    /// only with a result. A track with no steady beat
    /// gives an empty result rather than an error. Cancelling the calling task
    /// at any stage, from loading the track to tracking the beats, stops the
    /// work and throws `CancellationError`, never a result.
    static func detect(url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> BeatTrack {
        let work = Task.detached(priority: .utility) {
            try await detectBeats(url: url, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func detectBeats(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> BeatTrack {
        try Task.checkCancellation()
        let asset = MediaFile.asset(at: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw DetectionError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds
        try Task.checkCancellation()

        let handedOver = HandedOver(value: track)
        return try await SampleReading.run { isCancelled in
            if isCancelled() { throw CancellationError() }
            let track = handedOver.value
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw DetectionError.readerFailed("unsupported audio format") }
            reader.add(output)
            guard reader.startReading() else {
                throw DetectionError.readerFailed(reader.error?.localizedDescription ?? "unknown error", underlying: reader.error)
            }
            var source = ReaderSource(reader: reader, output: output)
            return try analyze(&source, duration: duration, isCancelled: isCancelled, progress: progress)
        }
    }

    /// The share of `progress` given to reading and decoding, by the
    /// buffers' timestamps; tracking the beats takes the rest. Tracking took
    /// about a fifth of the time on a three-minute song.
    static let readingShare = 0.8

    /// Finds the beats in the buffers `source` gives, which must be mono
    /// float PCM at `sampleRate`. `duration` is the asset's, in seconds.
    /// `progress` gets finite values in 0...1 that never decrease, through
    /// reading and then tracking, and 1 only once the result is ready.
    /// Throws `CancellationError` once `isCancelled` turns true, which is
    /// checked before every buffer (so also at the end of the audio), while
    /// a long gap is filled, through tracking, and before returning.
    /// Whatever goes wrong, the source is cancelled before this throws.
    static func analyze(
        _ source: inout some DecodedAudioSource, duration: Double,
        isCancelled: () -> Bool, progress: (Double) -> Void
    ) throws -> BeatTrack {
        do {
            // Only for the duration of the call, by the samples' feed.
            return try withoutActuallyEscaping(isCancelled) { isCancelled in
                try analyzeOrThrow(&source, duration: duration, isCancelled: isCancelled, progress: progress)
            }
        } catch {
            source.cancel()
            throw error
        }
    }

    private static func analyzeOrThrow(
        _ source: inout some DecodedAudioSource, duration: Double,
        isCancelled: @escaping () -> Bool, progress: (Double) -> Void
    ) throws -> BeatTrack {
        func checkCancellation() throws {
            if isCancelled() { throw CancellationError() }
        }
        let analyzer = OnsetAnalyzer()
        let seconds = duration.isFinite && duration > 0 ? duration : 0
        var timed = TimedSamples(
            longestGap: Int64(min(max(seconds, 60), 24 * 3600) * sampleRate),
            feed: { samples in
                try checkCancellation()
                analyzer.append(samples)
            }
        )
        var reported = 0.0
        /// Passes `value` on when it has grown by a hundredth; 1 only once.
        func report(_ value: Double) {
            guard value.isFinite else { return }
            let clamped = value.clamped(between: 0, and: 1)
            guard clamped == 1 ? reported < 1 : clamped - reported >= 0.01 else { return }
            reported = clamped
            progress(clamped)
        }

        while true {
            try checkCancellation()
            guard let sample = source.next() else { break }
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            try timed.append(pcmSamples(of: sample), at: presentation)

            if seconds > 0 {
                report((presentation.seconds / seconds).clamped(between: 0, and: 1) * readingShare)
            }
        }
        // A read cancelled at the end must not count as completed.
        try checkCancellation()
        // Only a read that got to the end may become a result: one that
        // stopped early would be saved as the beats of the whole file.
        try source.checkCompleted()
        report(readingShare)

        let origin = timed.origin ?? 0
        let beats = try BeatTracker.track(envelope: analyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond) { done in
            try checkCancellation()
            // Short of 1, which is for the finished result.
            report(readingShare + (1 - readingShare) * done.clamped(between: 0, and: 0.99))
        }
        try checkCancellation()
        guard let beats else {
            report(1)
            return .none(timescale: Int32(sampleRate))
        }
        let times = try beats.frames.map { frame -> Int64 in
            let (time, overflow) = origin.addingReportingOverflow(OnsetAnalyzer.centerSample(ofFrame: frame))
            guard !overflow else { throw DetectionError.malformedAudio("the audio's timestamps are out of range") }
            return time
        }
        let result = try BeatTrack(timescale: Int32(sampleRate), times: times, beatsPerMinute: beats.beatsPerMinute)
        report(1)
        return result
    }
}

/// Where `BeatDetector.analyze` gets decoded audio: an asset reader, or
/// buffers made up by a test.
protocol DecodedAudioSource {
    /// The next buffer, or nil once there are no more, whether because the
    /// end was reached or because reading stopped.
    mutating func next() -> CMSampleBuffer?
    /// Called after `next` gave nil. Throws unless all of the audio was read.
    func checkCompleted() throws
    /// Stops reading; called when analysis fails or is cancelled.
    func cancel()
}

struct ReaderSource: DecodedAudioSource {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput

    mutating func next() -> CMSampleBuffer? { output.copyNextSampleBuffer() }

    func checkCompleted() throws {
        switch reader.status {
        case .completed:
            return
        case .failed:
            throw BeatDetector.DetectionError.readerFailed(reader.error?.localizedDescription ?? "unknown error", underlying: reader.error)
        default:
            throw BeatDetector.DetectionError.readerFailed("reading stopped before the end", underlying: reader.error)
        }
    }

    func cancel() { reader.cancelReading() }
}
