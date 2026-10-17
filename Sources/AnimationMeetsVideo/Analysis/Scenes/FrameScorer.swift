import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Decodes a video at very low resolution and measures how much the picture
/// changes from each frame to the next. The result is what scene detection
/// and later sensitivity changes work from.
enum FrameScorer {
    /// Frames are compared at this size; a hard cut is obvious even at a
    /// fraction of the resolution, and it keeps decoding fast.
    static let sampleWidth = 64
    static let sampleHeight = 36

    enum ScoringError: LocalizedError {
        case noVideoTrack
        /// `underlying` is what the reader reported, kept so the cause can be told apart.
        case readerFailed(String, underlying: (any Error)? = nil)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The file has no video track to analyze."
            case .readerFailed(let reason, _): "Couldn't read the video: \(reason)"
            }
        }
    }

    /// Scores every frame of the first video track. `progress` receives 0...1
    /// and may be called from a background thread. Cancelling the calling task
    /// stops reading and throws `CancellationError`.
    static func score(url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ChangeScoreTrack {
        let work = Task.detached(priority: .utility) {
            try await scoreFrames(url: url, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func scoreFrames(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ChangeScoreTrack {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ScoringError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        let timescale = max(try await track.load(.naturalTimeScale), 600)
        // Where the track's edit list has no footage. The reader fills such a
        // stretch with a black sample of its own; it is not a frame of the
        // file, and the edit list, not how the sample looks, says so.
        let empty = EmptySegments(ranges: try await track.load(.segments).filter(\.isEmpty).map(\.timeMapping.target))

        let handedOver = HandedOver(value: track)
        return try await SampleReading.run { isCancelled in
            let track = handedOver.value
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: sampleWidth,
                kCVPixelBufferHeightKey as String: sampleHeight,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ScoringError.readerFailed("unsupported video format") }
            reader.add(output)
            guard reader.startReading() else {
                throw ScoringError.readerFailed(reader.error?.localizedDescription ?? "unknown error", underlying: reader.error)
            }

            var times: [Int64] = []
            var scores: [UInt8] = []
            var skipScores: [UInt8] = []
            var beforePrevious: [UInt8] = []
            var previous: [UInt8] = []
            var current: [UInt8] = []
            var lastReported = -1.0
            var lastPresentation: CMTime?

            while let sample = output.copyNextSampleBuffer() {
                if isCancelled() {
                    reader.cancelReading()
                    throw CancellationError()
                }
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
                // Not footage: neither a frame nor a baseline.
                if empty.contains(presentation) { continue }
                let time = CMTimeConvertScale(
                    presentation,
                    timescale: timescale,
                    method: .roundHalfAwayFromZero
                )
                // A track keeps only frames inside the asset whose times
                // increase: a repeated or backwards time can't be placed.
                if time.value < 0 || (times.last.map { time.value <= $0 } ?? false) { continue }
                copyLuma(from: pixels, into: &current)

                // The first real frame after an empty stretch, at the start
                // or in the middle, begins again: no change is scored
                // across it.
                if empty.separates(lastPresentation, presentation) {
                    previous = []
                    beforePrevious = []
                }
                lastPresentation = presentation
                scores.append(previous.isEmpty ? 0 : meanAbsoluteDifference(previous, current))
                skipScores.append(beforePrevious.isEmpty ? 0 : meanAbsoluteDifference(beforePrevious, current))
                times.append(time.value)
                beforePrevious = previous
                swap(&previous, &current)

                if duration > 0 {
                    let fraction = min(time.seconds / duration, 1)
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress(fraction)
                    }
                }
            }

            if reader.status == .failed {
                throw ScoringError.readerFailed(reader.error?.localizedDescription ?? "unknown error", underlying: reader.error)
            }
            progress(1)
            return ChangeScoreTrack(
                timescale: timescale, times: times, scores: scores, skipScores: skipScores,
                emptySpans: empty.spans(timescale: timescale)
            )
        }
    }

    /// Copies the luma plane without row padding.
    private static func copyLuma(from buffer: CVPixelBuffer, into pixels: inout [UInt8]) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            pixels = [UInt8](repeating: 0, count: width * height)
            return
        }
        pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let source = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                pixels[row * width + column] = source[column]
            }
        }
    }

    static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> UInt8 {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total = 0
        for i in 0..<a.count {
            total += abs(Int(a[i]) - Int(b[i]))
        }
        return UInt8(min((Double(total) / Double(a.count)).rounded(), 255))
    }
}

/// The stretches of a track's time (in the time of its samples) that its edit
/// list leaves empty.
struct EmptySegments: Sendable {
    var ranges: [CMTimeRange]

    /// Whether `time` is in an empty stretch (its end is the first moment of
    /// footage after it).
    func contains(_ time: CMTime) -> Bool {
        ranges.contains { CMTimeCompare(time, $0.start) >= 0 && CMTimeCompare(time, $0.end) < 0 }
    }

    /// Whether an empty stretch lies wholly between the previous frame and
    /// this one. With no previous frame, one that ends at or before this
    /// frame counts: the start of the footage.
    func separates(_ previous: CMTime?, _ time: CMTime) -> Bool {
        ranges.contains { range in
            CMTimeCompare(range.end, time) <= 0 && (previous.map { CMTimeCompare(range.start, $0) >= 0 } ?? true)
        }
    }

    func spans(timescale: Int32) -> [ChangeScoreTrack.EmptySpan] {
        ranges
            .map { range in
                ChangeScoreTrack.EmptySpan(
                    start: max(CMTimeConvertScale(range.start, timescale: timescale, method: .roundHalfAwayFromZero).value, 0),
                    end: CMTimeConvertScale(range.end, timescale: timescale, method: .roundHalfAwayFromZero).value
                )
            }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
    }
}
