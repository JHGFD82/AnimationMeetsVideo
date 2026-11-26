import AVFoundation
import CoreMedia
import Foundation

/// The timeline's frames around a paused playhead, kept in memory at a
/// reduced size, so scrubbing back and forth over that stretch shows them
/// at once instead of waiting on the player's seeks (docs/rendering.md,
/// "Scrub cache"). Long-GOP footage seeks slowly but reads quickly in
/// order, so the stretch is read in order through the player's own video
/// composition (`AVAssetReaderVideoCompositionOutput`), drawn by the
/// same compositor, at most `longestSide` pixels across.
///
/// It starts once the player has rested (`settleSeconds`), reads from
/// `behindSeconds` before the playhead to `aheadSeconds` after, and keeps
/// at most `budget` bytes, letting go of the frames furthest from where it
/// last rested first. Moving the playhead stops the reading but keeps the
/// frames; play stops it too; a new item or an edit lets go of them all
/// (`reset`). It waits while the Mac is hot or in Low Power Mode.
@MainActor
final class ScrubCache {
    /// The widest a kept frame is, in pixels.
    static let longestSide = 640.0
    /// The most the frames take: about seven seconds of 16:9 at 60 fps.
    static let budget = 384 << 20

    var settleSeconds = 0.4
    var behindSeconds = 3.0
    var aheadSeconds = 6.0

    private var frames: [Int: CVPixelBuffer] = [:]
    private(set) var keptBytes = 0
    private var frameRate = 0.0
    /// Where it last rested, as a frame, which the furthest frames are
    /// let go from.
    private var center = 0
    /// Bumped by `reset`, so a reading of what was there before keeps
    /// nothing.
    private var generation = 0
    private var task: Task<Void, Never>?

    /// How many frames it holds, for tests.
    var count: Int { frames.count }

    /// Lets go of every frame: the timeline it read is gone or changed.
    func reset(frameRate: Double) {
        cancel()
        generation += 1
        frames.removeAll()
        keptBytes = 0
        self.frameRate = frameRate
    }

    /// Stops reading; what was read stays.
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// The kept frame shown at `time`, if there is one.
    func frame(at time: CMTime) -> CVPixelBuffer? {
        guard frameRate > 0, time.isNumeric else { return nil }
        return frames[index(of: time.seconds)]
    }

    /// The frame showing at `seconds`: the last to start by then.
    private func index(of seconds: Double) -> Int {
        Int((seconds * frameRate + 1e-6).rounded(.down))
    }

    /// The scale a timeline `size` big is read at.
    static func scale(for size: CGSize) -> Double {
        min(1, longestSide / max(Double(max(size.width, size.height)), 1))
    }

    /// Starts reading around `time` from `composition` drawn by
    /// `videoComposition` (the player's, at the scale it is read at), in
    /// `pixelFormat`, after `settleSeconds`, skipping frames it holds.
    func fill(composition: AVComposition, videoComposition: AVVideoComposition, pixelFormat: OSType, around time: CMTime) {
        cancel()
        guard frameRate > 0, time.isNumeric, composition.duration.isNumeric else { return }
        center = index(of: time.seconds)
        let start = max(0, time.seconds - behindSeconds)
        let end = min(composition.duration.seconds, time.seconds + aheadSeconds)
        guard end > start else { return }
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600)
        )
        let generation = generation
        let settle = settleSeconds
        let handed = HandedOver(value: (composition, videoComposition))
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(settle))
            guard !Task.isCancelled, Self.machineIsFree else { return }
            await Self.read(range, of: handed, pixelFormat: pixelFormat) { buffer, at in
                guard let self, self.generation == generation else { return false }
                return self.keep(buffer, at: at)
            }
        }
    }

    /// Reads `range` of the composition in order, handing each frame to
    /// `keep` on the main actor until it says to stop or the task is
    /// cancelled.
    nonisolated private static func read(
        _ range: CMTimeRange, of handed: HandedOver<(AVComposition, AVVideoComposition)>, pixelFormat: OSType,
        keep: @MainActor @escaping (CVPixelBuffer, CMTime) -> Bool
    ) async {
        let (composition, videoComposition) = handed.value
        let tracks = composition.tracks(withMediaType: .video)
        guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: composition) else { return }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: any Sendable],
        ])
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else { return }
        defer { if reader.status == .reading { reader.cancelReading() } }
        while !Task.isCancelled, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let handedFrame = HandedOver(value: buffer)
            let goOn = await MainActor.run { keep(handedFrame.value, time) }
            guard goOn else { return }
        }
    }

    /// Keeps `buffer` as the frame at `time`, letting go of the furthest
    /// frames past the budget. False once the frame itself would be the
    /// furthest, so reading on is no use.
    private func keep(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        let index = index(of: time.seconds)
        if frames[index] != nil { return true }
        let size = CVPixelBufferGetDataSize(buffer)
        while keptBytes + size > Self.budget {
            guard let furthest = frames.keys.max(by: { abs($0 - center) < abs($1 - center) }),
                  abs(furthest - center) > abs(index - center),
                  let dropped = frames.removeValue(forKey: furthest)
            else { return false }
            keptBytes -= CVPixelBufferGetDataSize(dropped)
        }
        frames[index] = buffer
        keptBytes += size
        return true
    }

    nonisolated private static var machineIsFree: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        return thermal != .serious && thermal != .critical && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
