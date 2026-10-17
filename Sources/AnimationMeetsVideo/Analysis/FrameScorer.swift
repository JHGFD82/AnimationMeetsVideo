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
            var previous: [UInt8] = []
            var current: [UInt8] = []
            var lastReported = -1.0

            while let sample = output.copyNextSampleBuffer() {
                if isCancelled() {
                    reader.cancelReading()
                    throw CancellationError()
                }
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                let time = CMTimeConvertScale(
                    CMSampleBufferGetPresentationTimeStamp(sample),
                    timescale: timescale,
                    method: .roundHalfAwayFromZero
                )
                copyLuma(from: pixels, into: &current)

                scores.append(previous.isEmpty ? 0 : meanAbsoluteDifference(previous, current))
                times.append(time.value)
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
            return ChangeScoreTrack(timescale: timescale, times: times, scores: scores)
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
