import AVFoundation
import ImageIO
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

@Suite struct ReferenceThumbnailTimeTests {
    private func track(frames: Int, spikes: [Int: UInt8]) -> ChangeScoreTrack {
        ChangeScoreTrack(
            timescale: 24,
            times: (0..<frames).map(Int64.init),
            scores: (0..<frames).map { $0 == 0 ? 0 : (spikes[$0] ?? 3) }
        )
    }

    @Test func includesBothEndsAndBothSidesOfEachCut() {
        let times = ReferenceThumbnailCapture.times(for: track(frames: 100, spikes: [30: 200, 70: 200])).map(\.value)
        #expect(times == [0, 29, 30, 69, 70, 99])
    }

    @Test func addsFramesAtRegularIntervals() {
        let times = ReferenceThumbnailCapture.times(for: track(frames: 24 * 35, spikes: [:])).map(\.value)
        #expect(times == [0, 240, 480, 720, 24 * 35 - 1])
    }

    @Test func listIsSortedAndFreeOfDuplicates() {
        let times = ReferenceThumbnailCapture.times(for: track(frames: 600, spikes: [239: 200, 240: 200, 300: 200])).map(\.value)
        #expect(times == times.sorted())
        #expect(Set(times).count == times.count)
        #expect(times.contains(240) && times.contains(299) && times.contains(300))
    }

    @Test func strongestCutsWinWhenThereAreTooMany() {
        let frames = 24 * 3000
        var spikes: [Int: UInt8] = [:]
        for index in 0..<(ReferenceThumbnailCapture.maximumCuts + 50) {
            spikes[24 * (index + 1) * 2] = index < 50 ? 120 : 250
        }
        let t = track(frames: frames, spikes: spikes)
        let times = Set(ReferenceThumbnailCapture.times(for: t).map(\.value))
        #expect(times.contains(Int64(24 * (ReferenceThumbnailCapture.maximumCuts + 50) * 2)))
        #expect(!times.contains(47))
    }

    @Test func emptyTrackHasNoFrames() {
        #expect(ReferenceThumbnailCapture.times(for: ChangeScoreTrack(timescale: 24, times: [], scores: [])).isEmpty)
    }

    @Test func nearestIndexPicksTheClosestFrame() {
        let t = ChangeScoreTrack(timescale: 100, times: [0, 40, 100, 130], scores: [0, 0, 0, 0])
        #expect(t.index(nearestTo: 55) == 1)
        #expect(t.index(nearestTo: 75) == 2)
        #expect(t.index(nearestTo: 9_999) == 3)
        #expect(t.index(ofFrameAt: CMTime(value: 130, timescale: 100)) == 3)
        #expect(t.index(ofFrameAt: CMTime(value: 131, timescale: 100)) == nil)
    }
}

@Suite struct ReferenceThumbnailCaptureTests {
    @Test func capturesJPEGFramesAtTheRequestedTimes() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-thumbs-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeMovie(to: url, segments: [(0, 24), (255, 24)])
        let times = [CMTime(value: 23, timescale: 24), CMTime(value: 24, timescale: 24)]

        let pictures = try await ReferenceThumbnailCapture.capture(url: url, times: times)

        #expect(pictures.frames.map(\.time) == times)
        func brightness(_ frame: ReferenceFrame) throws -> Double {
            let source = try #require(CGImageSourceCreateWithData(frame.jpeg as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width <= ReferenceThumbnailCapture.width && image.height <= ReferenceThumbnailCapture.height)
            let data = try #require(image.dataProvider?.data)
            return Double(CFDataGetBytePtr(data)[0])
        }
        #expect(try brightness(pictures.frames[0]) < 40)
        #expect(try brightness(pictures.frames[1]) > 215)
    }

    @Test func framesThatCannotBeReadAreSkipped() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-thumbs-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeMovie(to: url, segments: [(100, 24)])

        let pictures = try await ReferenceThumbnailCapture.capture(
            url: url, times: [CMTime(value: 5, timescale: 24), CMTime(value: 500, timescale: 1)]
        )

        #expect(pictures.frames.count == 1)
    }
}
