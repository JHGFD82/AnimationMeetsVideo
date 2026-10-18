import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Tones to play through a timeline's audio mix, and reading what comes out
/// the way an export reads it.
enum AudioMixSupport {
    static let sampleRate = 48_000.0

    /// Writes a WAV file of `seconds` of a sine at `frequency` (or a steady
    /// level for 0) peaking at `amplitude`, on every channel.
    static func tone(
        channels: AVAudioChannelCount = 2, frequency: Double = 0, amplitude: Float = 0.25, seconds: Double = 1
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-tone-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let count = Int(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for index in 0..<count {
                data[index] = frequency == 0 ? amplitude : amplitude * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// A project whose root timeline plays `url` from the start, with the
    /// clip's and its layer's IDs.
    static func project(playing url: URL, seconds: Double = 1) throws -> (EditingProject, clipID: UUID, layerID: UUID) {
        var project = EditingProject.empty
        let media = MediaClip(
            name: "Tone", kind: .audio, url: url, duration: CMTime(seconds: seconds, preferredTimescale: 48_000),
            frameRate: 0, colorSpace: .rec709, codecName: "PCM", hasAudio: true
        )
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        return (project, ids.clipID, ids.layerID)
    }

    /// The loudest left and right samples of the root timeline's mix after
    /// `skip` seconds, read in stereo.
    static func loudest(of project: EditingProject, after skip: Double = 0) async throws -> SIMD2<Float> {
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        let reader = try AVAssetReader(asset: composed.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: composed.composition.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 2,
        ])
        output.audioMix = composed.audioMix(curves: MixCurves(MixCurves.of(project)))
        reader.add(output)
        #expect(reader.startReading())
        var loudest = SIMD2<Float>.zero
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            for frame in 0..<chunk.count / 2 where start + Double(frame) / sampleRate >= skip {
                loudest = pointwiseMax(loudest, SIMD2(abs(chunk[2 * frame]), abs(chunk[2 * frame + 1])))
            }
        }
        return loudest
    }
}
