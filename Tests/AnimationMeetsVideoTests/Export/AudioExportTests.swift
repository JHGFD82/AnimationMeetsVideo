import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct AudioExportTests {
    /// A file's format and its loudest sample on each side.
    private func read(_ url: URL) throws -> (settings: [String: Any], seconds: Double, loudest: SIMD2<Float>) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        var loudest = SIMD2<Float>.zero
        for frame in 0..<Int(buffer.frameLength) {
            loudest = pointwiseMax(loudest, SIMD2(abs(buffer.floatChannelData![0][frame]), abs(buffer.floatChannelData![1][frame])))
        }
        return (file.fileFormat.settings, Double(file.length) / file.fileFormat.sampleRate, loudest)
    }

    @Test func theMixIsA24BitWAVOfWhatPlays() async throws {
        let tone = try AudioMixSupport.tone(frequency: 440, amplitude: 0.25, seconds: 2)
        defer { try? FileManager.default.removeItem(at: tone) }
        var (project, clipID, _) = try AudioMixSupport.project(playing: tone, seconds: 2)
        project.editClip(clipID, in: project.rootTimelineID) { $0.pan.set(-100, at: .zero) }
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-mix-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try await AudioExport.exportMix(project: project, timelineID: project.rootTimelineID, loudness: .asMixed, to: url)
        let file = try read(url)
        #expect(file.settings[AVLinearPCMBitDepthKey] as? Int == 24)
        #expect(file.settings[AVSampleRateKey] as? Double == 48_000)
        #expect(abs(file.seconds - 2) < 0.01)
        // Panned hard left, as it plays.
        #expect(abs(file.loudest.x - 0.25) < 0.005)
        #expect(file.loudest.y < 0.001)
    }

    @Test func eachStemHasOnlyItsLayer() async throws {
        let low = try AudioMixSupport.tone(frequency: 220, amplitude: 0.2, seconds: 1)
        let high = try AudioMixSupport.tone(frequency: 880, amplitude: 0.4, seconds: 1)
        defer {
            try? FileManager.default.removeItem(at: low)
            try? FileManager.default.removeItem(at: high)
        }
        var (project, _, _) = try AudioMixSupport.project(playing: low)
        let media = MediaClip(
            name: "High", kind: .audio, url: high, duration: CMTime(value: 1, timescale: 1),
            frameRate: 0, colorSpace: .rec709, codecName: "PCM", hasAudio: true
        )
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let second = try #require(imported)
        project.editVolume(of: second.layerID, in: project.rootTimelineID) { $0.set(-6, at: .zero) }

        let folder = FileManager.default.temporaryDirectory.appending(path: "amv-stems-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try await AudioExport.exportStems(project: project, timelineID: project.rootTimelineID, named: "Cut", in: folder)
        #expect(files.count == 2)
        let levels = try files.map { try read($0).loudest.x }.sorted()
        // The quiet tone alone, and the loud one at its layer's −6 dB.
        #expect(abs(levels[0] - 0.2) < 0.01)
        #expect(abs(levels[1] - 0.4 * AudioLevel.gain(decibels: -6)) < 0.01)
        #expect(files.allSatisfy { $0.lastPathComponent.hasPrefix("Cut - ") && $0.pathExtension == "wav" })
    }

    @Test func aTimelineWithoutSoundIsRefused() async throws {
        let project = EditingProject.empty
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-silent-\(UUID().uuidString).wav")
        await #expect(throws: CompositionError.self) {
            try await AudioExport.exportMix(project: project, timelineID: project.rootTimelineID, loudness: .asMixed, to: url)
        }
    }
}
