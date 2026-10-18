import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Mastering an export's sound to a loudness target.
@Suite struct LoudnessMasteringTests {
    private func composed(_ project: EditingProject) async throws -> ComposedTimeline {
        try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
    }

    /// The loudness and peak of a rendered file.
    private func measureFile(_ url: URL) throws -> (lufs: Double, peak: Float, seconds: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        var measurement = LoudnessMeasurement(sampleRate: file.processingFormat.sampleRate, channels: Int(file.processingFormat.channelCount))
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength) * Int(file.processingFormat.channelCount))
        measurement.add(interleaved: samples)
        return (measurement.integrated, measurement.peak, Double(file.length) / file.processingFormat.sampleRate)
    }

    @Test func aQuietMixIsRaisedToTheTarget() async throws {
        let url = try AudioMixSupport.tone(frequency: 997, amplitude: 0.0316, seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let (project, _, _) = try AudioMixSupport.project(playing: url, seconds: 3)
        let timeline = try await composed(project)
        let directory = FileManager.default.temporaryDirectory
        let result = try await LoudnessMastering.master(
            timeline, curves: MixCurves(MixCurves.of(project)), to: .podcast, in: directory
        )
        let (report, file) = try #require(result)
        defer { try? FileManager.default.removeItem(at: file) }
        // A sine at 0.0316 on both sides is −30 LUFS.
        #expect(abs(report.measured - -30) < 0.2)
        #expect(abs(report.gain - 14) < 0.2)
        let rendered = try measureFile(file)
        #expect(abs(rendered.lufs - -16) < 0.3)
        #expect(abs(rendered.seconds - 3) < 0.01)
        // Its sound replaced the composition's.
        #expect(timeline.composition.tracks(withMediaType: .audio).count == 1)
    }

    @Test func peaksAreHeldUnderTheCeiling() async throws {
        // A quiet sine with sharp clicks every 50 ms: quieter than −20
        // LUFS with peaks of 0.9, so reaching −14 LUFS takes more gain than
        // the clicks have room for.
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-clicks-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 48_000.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 3)))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                let click: Float = frame % 2400 < 4 ? 0.9 : 0
                buffer.floatChannelData![channel][frame] = click + 0.01 * Float(sin(2 * .pi * 997 * Double(frame) / rate))
            }
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let (project, _, _) = try AudioMixSupport.project(playing: url, seconds: 3)
        let timeline = try await composed(project)
        let result = try await LoudnessMastering.master(
            timeline, curves: MixCurves(MixCurves.of(project)), to: .streaming, in: FileManager.default.temporaryDirectory
        )
        let (report, file) = try #require(result)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(report.gain > 6)
        let rendered = try measureFile(file)
        #expect(rendered.peak <= Float(pow(10, LoudnessMastering.ceiling / 20)) + 0.01)
        #expect(rendered.peak > 0.5)
    }

    @Test func asMixedChangesNothing() async throws {
        let url = try AudioMixSupport.tone(frequency: 997, amplitude: 0.1, seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let (project, _, _) = try AudioMixSupport.project(playing: url)
        let timeline = try await composed(project)
        let result = try await LoudnessMastering.master(
            timeline, curves: MixCurves(MixCurves.of(project)), to: .asMixed, in: FileManager.default.temporaryDirectory
        )
        #expect(result == nil)
    }
}
