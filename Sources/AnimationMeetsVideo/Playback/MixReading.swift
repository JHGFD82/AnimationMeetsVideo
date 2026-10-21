import AVFoundation
import CoreMedia
import Foundation

/// Reads a stretch of a timeline's mix out through its audio mix, as
/// playback hears it, or of a file's own sound, for the scrubbers to play
/// from.
enum MixReading {
    /// The mix from `start` for `duration` seconds, stereo at
    /// `sampleRate`, with where its first sample falls in the timeline.
    /// Nil when there is no sound there. Blocks while it reads, so it is
    /// only called on a scrubber's own queue.
    static func read(
        _ composed: ComposedTimeline?, curves: MixCurves?, from start: Double, duration: Double, sampleRate: Double
    ) -> (start: Double, left: [Float], right: [Float])? {
        guard let composed, let curves, !composed.audioTracks.isEmpty else { return nil }
        return read(
            composed.composition, tracks: composed.composition.tracks(withMediaType: .audio), audioMix: composed.audioMix(curves: curves),
            from: start, duration: duration, sampleRate: sampleRate
        )
    }

    /// `tracks` of `asset` mixed, through `audioMix` when there is one,
    /// from `start` for `duration` seconds as `read` reads a mix: a file's
    /// own sound, for skimming it in the browser. Times are the asset's.
    static func read(
        _ asset: AVAsset, tracks: [AVAssetTrack], audioMix: AVAudioMix? = nil, from start: Double, duration: Double, sampleRate: Double
    ) -> (start: Double, left: [Float], right: [Float])? {
        guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ])
        output.audioMix = audioMix
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 48_000),
            duration: CMTime(seconds: duration, preferredTimescale: 48_000)
        )
        guard reader.startReading() else { return nil }
        var left: [Float] = [], right: [Float] = []
        var first: Double?
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            if first == nil { first = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
            var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            for frame in 0..<samples.count / 2 {
                left.append(samples[2 * frame])
                right.append(samples[2 * frame + 1])
            }
        }
        guard let first, !left.isEmpty else { return nil }
        return (first, left, right)
    }
}
