import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One saved picture from an asset's original file.
struct ReferenceFrame: Equatable, Sendable {
    var time: CMTime
    var jpeg: Data
}

/// Pictures kept from the original file so the sync dialog can still show it
/// after the file is replaced. Taken just before and after each cut, at
/// regular intervals, and at both ends.
struct ReferenceThumbnails: Equatable, Sendable {
    /// In time order.
    var frames: [ReferenceFrame]
}

enum ReferenceThumbnailCapture {
    static let width = 256
    static let height = 144
    static let intervalSeconds = 10.0
    /// Cuts are taken at a loose setting, so frames exist for more of the
    /// cuts a person may later turn on.
    static let cutSensitivity = 0.8
    /// Cap on cuts, strongest first, to bound the size of the saved data.
    static let maximumCuts = 600

    /// Frame times to save, in order. Always real frames of `track`.
    static func times(for track: ChangeScoreTrack) -> [CMTime] {
        guard track.frameCount > 0 else { return [] }
        var indices: Set<Int> = [0, track.frameCount - 1]

        var cutIndices: [Int] = []
        for time in SceneDetector.autoCuts(in: track, defaultSensitivity: cutSensitivity) {
            if let index = track.index(ofFrameAt: time) { cutIndices.append(index) }
        }
        if cutIndices.count > maximumCuts {
            cutIndices = Array(cutIndices.sorted { track.scores[$0] > track.scores[$1] }.prefix(maximumCuts))
        }
        for index in cutIndices {
            indices.insert(index)
            indices.insert(index - 1)
        }

        let step = Int64(intervalSeconds * Double(track.timescale))
        if step > 0, let last = track.times.last {
            var target = track.times[0] + step
            while target < last {
                indices.insert(track.index(nearestTo: target))
                target += step
            }
        }
        return indices.sorted().map { track.time(at: $0) }
    }

    /// Reads and compresses the frames at `times`. Frames that can't be read
    /// are skipped. Cancelling stops early and throws `CancellationError`.
    static func capture(
        url: URL,
        times: [CMTime],
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ReferenceThumbnails {
        let work = Task.detached(priority: .utility) { () -> ReferenceThumbnails in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: width, height: height)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            var frames: [ReferenceFrame] = []
            var done = 0
            for await result in generator.images(for: times) {
                try Task.checkCancellation()
                done += 1
                progress(Double(done) / Double(max(times.count, 1)))
                guard case .success(let requested, let image, _) = result, let jpeg = jpegData(image) else { continue }
                frames.append(ReferenceFrame(time: requested, jpeg: jpeg))
            }
            frames.sort { CMTimeCompare($0.time, $1.time) < 0 }
            return ReferenceThumbnails(frames: frames)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

extension ChangeScoreTrack {
    /// Index of the frame at exactly `time`, if there is one.
    func index(ofFrameAt time: CMTime) -> Int? {
        let target = time.convertScale(timescale, method: .default).value
        let index = index(nearestTo: target)
        return times.indices.contains(index) && times[index] == target ? index : nil
    }

    /// Index of the frame closest to `target`, in this track's time units.
    func index(nearestTo target: Int64) -> Int {
        var low = 0, high = times.count - 1
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < target { low = mid + 1 } else { high = mid }
        }
        if low > 0, target - times[low - 1] <= times[low] - target { low -= 1 }
        return low
    }
}
