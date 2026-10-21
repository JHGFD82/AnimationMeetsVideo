import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct MediaFileTests {
    static let sampleRate = 48_000.0

    /// A read from partway into a FLAC file starts with the samples a read
    /// from the start has at that time. AVFoundation only seeks FLAC to the
    /// exact sample when asked for precise timing; otherwise it lands up
    /// to seconds away, which the Beat Match panel heard as audio out of
    /// step with its playhead after a click.
    @Test func seeksIntoFLACLandOnTheSampleAskedFor() async throws {
        let url = try Self.noiseFLAC(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let whole = try await Self.read(url, from: nil)
        for seconds in [5.0, 17.3, 24.0] {
            let part = try await Self.read(url, from: seconds)
            let index = Int(seconds * Self.sampleRate)
            #expect(part.count >= 1_024)
            let matches = zip(part.prefix(1_024), whole[index..<index + 1_024]).allSatisfy { abs($0 - $1) < 1e-4 }
            #expect(matches, "a read from \(seconds) s starts elsewhere in the file")
        }
    }

    /// Mono noise whose loudness drifts, so no stretch of it looks like
    /// another.
    private static func noiseFLAC(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-noise-\(UUID().uuidString).flac")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let count = Int(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let data = try #require(buffer.floatChannelData?[0])
        var generator = SystemRandomNumberGenerator()
        for index in 0..<count {
            let level = 0.2 + 0.15 * sin(Double(index) / sampleRate * 0.7)
            data[index] = Float(Double.random(in: -1...1, using: &generator) * level)
        }
        try file.write(from: buffer)
        return url
    }

    /// The file's samples as mono floats, through `MediaFile`, from the
    /// start or from `seconds` for a second.
    private static func read(_ url: URL, from seconds: Double?) async throws -> [Float] {
        let asset = MediaFile.asset(at: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let handedOver = HandedOver(value: (asset, track))
        return try await SampleReading.run { _ in
            let (asset, track) = handedOver.value
            let reader = try AVAssetReader(asset: asset)
            if let seconds {
                reader.timeRange = CMTimeRange(
                    start: CMTime(seconds: seconds, preferredTimescale: 48_000), duration: CMTime(seconds: 1, preferredTimescale: 48_000)
                )
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CancellationError() }
            var samples: [Float] = []
            while let buffer = output.copyNextSampleBuffer() {
                samples += try BeatDetector.pcmSamples(of: buffer, sampleRate: sampleRate)
            }
            return samples
        }
    }
}
