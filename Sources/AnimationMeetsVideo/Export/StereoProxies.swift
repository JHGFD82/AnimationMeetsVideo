import AVFoundation
import Foundation

/// Stereo copies of mono sound files, so a mono clip can be panned. A
/// composition track's audio tap sees only the channels its source has, and
/// the mix plays one channel on both sides, so a mono source can't be moved
/// between them; its copy has the same sound on both channels, which pan
/// can turn down one at a time. See docs/audio.md, "Pan".
///
/// A copy is made once per file and kept in the user's Caches folder, named
/// for the file's path, size and modification date, so a changed file gets
/// a new one. It is timed like the source's sound: silence fills in before
/// a sound track that starts late, so file times mean the same in both.
enum StereoProxies {
    /// The folder copies are kept in.
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.jhgfd.animationmeetsvideo/StereoProxies", directoryHint: .isDirectory)
    }

    /// The copy's track info for `info`'s file, made first if need be. Nil
    /// when the file's sound isn't mono or can't be read.
    static func stereo(for info: MediaTrackInfo) async throws -> MediaTrackInfo? {
        guard info.audioChannels == 1, let track = info.audio else { return nil }
        let url = info.asset.url
        guard let name = cacheName(for: url) else { return nil }
        let destination = folder.appending(path: name)
        if !FileManager.default.fileExists(atPath: destination.path) {
            let source = HandedOver(value: (info.asset, track, info.audioRange))
            try await SampleReading.run { isCancelled in
                let (asset, track, range) = source.value
                try write(asset: asset, track: track, range: range, to: destination, isCancelled: isCancelled)
            }
        }
        return try await MediaTrackCache.shared.info(for: destination)
    }

    /// The copy's file name: a hash of the path, size and modification
    /// date. Nil when the file can't be looked at.
    static func cacheName(for url: URL) -> String? {
        FileStamp.cacheDigest(for: url).map { "\($0).caf" }
    }

    /// Reads the mono track and writes it on both channels of a 24-bit CAF,
    /// after silence for the track's late start, into a temporary file that
    /// is moved into place when done, so a copy half made is never used.
    private static func write(
        asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange, to destination: URL, isCancelled: @Sendable () -> Bool
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CompositionError.exportFailed("A mono file couldn't be read.") }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appending(path: "\(UUID().uuidString).partial.caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var file: AVAudioFile?
        var buffer: AVAudioPCMBuffer?

        func append(_ samples: UnsafeBufferPointer<Float>, rate: Double) throws {
            if file == nil {
                guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
                file = try AVAudioFile(forWriting: temporary, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
                buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
                // The track's late start, as silence.
                let lead = Int((range.start.seconds * rate).rounded())
                if lead > 0 { try appendSilence(lead) }
            }
            guard let file, let buffer else { return }
            var offset = 0
            while offset < samples.count {
                let frames = min(Int(buffer.frameCapacity), samples.count - offset)
                for channel in 0..<2 {
                    buffer.floatChannelData![channel].update(from: samples.baseAddress! + offset, count: frames)
                }
                buffer.frameLength = AVAudioFrameCount(frames)
                try file.write(from: buffer)
                offset += frames
            }
        }

        func appendSilence(_ count: Int) throws {
            guard let file, let buffer else { return }
            var left = count
            while left > 0 {
                let frames = min(Int(buffer.frameCapacity), left)
                for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0, count: frames) }
                buffer.frameLength = AVAudioFrameCount(frames)
                try file.write(from: buffer)
                left -= frames
            }
        }

        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(sample),
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)
            else { continue }
            var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            try samples.withUnsafeBufferPointer { try append($0, rate: basic.pointee.mSampleRate) }
        }
        if reader.status == .failed { throw reader.error ?? CompositionError.exportFailed("A mono file couldn't be read.") }
        guard file != nil else { throw CompositionError.exportFailed("A mono file had no sound to copy.") }
        file = nil
        // Another build may have made the same copy meanwhile; either is
        // the same.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}
