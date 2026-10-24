import AVFoundation
import CoreMedia
import Foundation

/// What the beat match panel reads from a song, once, when it opens: the
/// samples at the file's own rate for a waveform that zooms down to single
/// samples, and an onset curve fine enough to place beats within a few
/// milliseconds. Times are converted to the asset's original time, the
/// time of its beat map.
struct BeatMatchAudio: Sendable {
    /// Mono, at `sampleRate`, from the start of the file's audio.
    let samples: [Float]
    /// The file's own rate, so a nudge of one sample is one of the file's.
    let sampleRate: Double
    /// The original time, in seconds, of `samples[0]`.
    let start: Double
    let curve: OnsetCurve
    /// Loudest and quietest sample per bucket, for drawing zoomed out.
    let levels: [WaveLevel]
    /// The largest sample, either way; decoded audio can go past 1. The
    /// waveform is drawn to it, so it always fits.
    let peak: Float

    /// The onset curve's hop: 2.9 ms frames, against detection's 11.6.
    static let onsetHop = 64

    struct WaveLevel: Sendable {
        let samplesPerBucket: Int
        let low: [Float]
        let high: [Float]
    }

    var duration: Double { Double(samples.count) / sampleRate }

    /// The original time of a sample, and back.
    func seconds(atSample index: Int) -> Double { start + Double(index) / sampleRate }
    func sample(atSeconds seconds: Double) -> Double { (seconds - start) * sampleRate }

    /// The coarsest level whose buckets are no wider than `samplesPerPoint`,
    /// or nil when the samples themselves should be drawn.
    func level(forSamplesPerPoint samplesPerPoint: Double) -> WaveLevel? {
        levels.last { Double($0.samplesPerBucket) <= samplesPerPoint }
    }

    init(samples: [Float], sampleRate: Double, start: Double, curve: OnsetCurve) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.start = start
        self.curve = curve
        var levels: [WaveLevel] = []
        for size in [16, 256, 4096] where samples.count > size {
            var low = [Float](), high = [Float]()
            low.reserveCapacity(samples.count / size + 1)
            high.reserveCapacity(samples.count / size + 1)
            var index = 0
            while index < samples.count {
                let bucket = samples[index..<min(samples.count, index + size)]
                low.append(bucket.min() ?? 0)
                high.append(bucket.max() ?? 0)
                index += size
            }
            levels.append(WaveLevel(samplesPerBucket: size, low: low, high: high))
        }
        self.levels = levels
        let top = levels.first.map { max($0.high.max() ?? 0, -($0.low.min() ?? 0)) }
            ?? samples.map(abs).max() ?? 0
        peak = max(top, 1e-6)
    }

    /// Reads the first audio track of `url`. `alignment` is the asset's
    /// alignment offset, so that original time `t` is at `t + alignment` in
    /// the file. Cancelling the calling task stops the read.
    static func load(url: URL, alignment: CMTime, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> BeatMatchAudio {
        let asset = MediaFile.asset(at: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw BeatDetector.DetectionError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds
        let formats = try await track.load(.formatDescriptions)
        let nativeRate = formats.lazy
            .compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
            .first { $0 > 0 } ?? 48_000
        try Task.checkCancellation()
        let offset = alignment.seconds.isFinite ? alignment.seconds : 0

        let handedOver = HandedOver(value: (asset, track))
        return try await SampleReading.run { isCancelled in
            let (asset, track) = handedOver.value
            // Two reads of the same track: at the file's rate to draw, at the
            // detector's to find onsets.
            var native: [Float] = []
            let nativeOrigin = try read(asset: asset, track: track, rate: nativeRate, duration: duration, isCancelled: isCancelled) {
                progress(0.5 * $0)
            } feed: { native.append(contentsOf: $0) }

            let analyzer = OnsetAnalyzer(hop: onsetHop)
            let onsetOrigin = try read(asset: asset, track: track, rate: BeatDetector.sampleRate, duration: duration, isCancelled: isCancelled) {
                progress(0.5 + 0.45 * $0)
            } feed: { analyzer.append($0) }
            if isCancelled() { throw CancellationError() }

            let values = BeatTracker.prepared(analyzer.envelope, framesPerSecond: analyzer.framesPerSecond)
                ?? [Float](repeating: 0, count: analyzer.envelope.count)
            let firstCenter = (Double(onsetOrigin) + Double(OnsetAnalyzer.windowSize) / 2) / BeatDetector.sampleRate
            let curve = OnsetCurve(values: values, framesPerSecond: analyzer.framesPerSecond, start: firstCenter - offset)
            let audio = BeatMatchAudio(
                samples: native, sampleRate: nativeRate, start: Double(nativeOrigin) / nativeRate - offset, curve: curve
            )
            progress(1)
            return audio
        }
    }

    /// Reads the track as mono floats at `rate`, placed by their timestamps,
    /// and gives where the first sample is, in samples at `rate`.
    private static func read(
        asset: AVURLAsset, track: AVAssetTrack, rate: Double, duration: Double,
        isCancelled: () -> Bool, progress: (Double) -> Void, feed: @escaping (UnsafeBufferPointer<Float>) -> Void
    ) throws -> Int64 {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw BeatDetector.DetectionError.readerFailed("unsupported audio format") }
        reader.add(output)
        guard reader.startReading() else {
            throw BeatDetector.DetectionError.readerFailed(reader.error?.localizedDescription ?? "unknown error", underlying: reader.error)
        }
        var source = ReaderSource(reader: reader, output: output)
        let seconds = duration.isFinite && duration > 0 ? duration : 0
        var timed = TimedSamples(longestGap: Int64(seconds.clamped(between: 60, and: 24 * 3600) * rate), sampleRate: rate) { feed($0) }
        do {
            while true {
                if isCancelled() { throw CancellationError() }
                guard let buffer = source.next() else { break }
                let presentation = CMSampleBufferGetPresentationTimeStamp(buffer)
                try timed.append(BeatDetector.pcmSamples(of: buffer, sampleRate: rate), at: presentation)
                if seconds > 0 { progress((presentation.seconds / seconds).clamped(between: 0, and: 1)) }
            }
            if isCancelled() { throw CancellationError() }
            try source.checkCompleted()
        } catch {
            source.cancel()
            throw error
        }
        return timed.origin ?? 0
    }
}
