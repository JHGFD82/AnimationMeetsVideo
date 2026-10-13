import AVFoundation
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Writes a mono WAV file with `segments` of (amplitude, seconds) of a 440 Hz tone.
func writeTone(to url: URL, segments: [(amplitude: Float, seconds: Double)], sampleRate: Double = 44100) throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    var phase = 0.0
    for segment in segments {
        let frames = AVAudioFrameCount(segment.seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            channel[index] = segment.amplitude * Float(sin(phase))
            phase += 2 * .pi * 440 / sampleRate
        }
        try file.write(from: buffer)
    }
}

@Suite struct AudioEnvelopeTests {
    @Test func levelsMapSilenceToZeroAndFullScaleToMax() {
        #expect(AudioEnvelope.level(forRMS: 0) == 0)
        #expect(AudioEnvelope.level(forRMS: 1e-6) == 0)
        #expect(AudioEnvelope.level(forRMS: 1) == 255)
        #expect(AudioEnvelope.level(forRMS: 0.1) > AudioEnvelope.level(forRMS: 0.01))
    }

    @Test func roundTripsThroughBinaryForm() throws {
        let envelope = AudioEnvelope(startWindow: -3, levels: [0, 5, 255, 17])
        #expect(try AudioEnvelope(decoding: envelope.encoded()) == envelope)
    }

    @Test func rejectsOtherFilesAndDamage() {
        #expect(throws: AudioEnvelopeError.self) { try AudioEnvelope(decoding: Data("nope".utf8)) }
        let good = AudioEnvelope(startWindow: 0, levels: [1, 2, 3]).encoded()
        #expect(throws: AudioEnvelopeError.self) { try AudioEnvelope(decoding: good.dropLast()) }
    }
}

@Suite struct ReferenceCaptureTests {
    private func temporary(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "amv-ref-\(UUID().uuidString).\(ext)")
    }

    @Test func envelopeFollowsTheLoudnessOfTheAudio() async throws {
        let url = temporary("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTone(to: url, segments: [(0, 1), (0.5, 1), (0, 1)])

        let envelope = try #require(try await ReferenceCapture.audioEnvelope(url: url))

        #expect(abs(envelope.duration - 3) < 0.05)
        #expect(envelope.startWindow == 0)
        #expect(envelope.levels[50] == 0)
        #expect(envelope.levels[150] > 150)
        #expect(envelope.levels[250] == 0)
    }

    @Test func fileWithoutAudioHasNoEnvelope() async throws {
        let url = temporary("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeMovie(to: url, segments: [(100, 24)])
        #expect(try await ReferenceCapture.audioEnvelope(url: url) == nil)
    }

    @Test func metadataDescribesAVideoFile() async throws {
        let url = temporary("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeMovie(to: url, segments: [(0, 24), (255, 24)])

        let metadata = try await ReferenceCapture.metadata(for: url)

        #expect(metadata.isVideo)
        #expect(!metadata.hasAudio)
        #expect(metadata.width == 128 && metadata.height == 72)
        #expect(metadata.codecName == "H.264")
        #expect(abs(metadata.duration.seconds - 2) < 0.1)
        #expect(metadata.fileName == url.lastPathComponent)
        #expect(metadata.byteCount > 0)
    }

    @Test func metadataDescribesAnAudioFile() async throws {
        let url = temporary("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTone(to: url, segments: [(0.5, 1)], sampleRate: 48000)

        let reference = try await ReferenceCapture.capture(url: url)

        #expect(!reference.metadata.isVideo)
        #expect(reference.metadata.audioSampleRate == 48000)
        #expect(reference.metadata.width == 0)
        #expect(reference.audioEnvelope != nil)
    }

    @Test func snapshotNoticesWhenTheFileIsSwapped() async throws {
        let url = temporary("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTone(to: url, segments: [(0.5, 1)])
        let metadata = try await ReferenceCapture.metadata(for: url)
        #expect(metadata.describes(fileAt: url))

        try FileManager.default.removeItem(at: url)
        try writeTone(to: url, segments: [(0.5, 2)])
        #expect(!metadata.describes(fileAt: url))
        #expect(!metadata.describes(fileAt: url.appendingPathExtension("gone")))
    }

    @Test func nonMediaFilesAreRejected() async throws {
        let url = temporary("mov")
        try Data("nope".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) { try await ReferenceCapture.capture(url: url) }
    }
}
