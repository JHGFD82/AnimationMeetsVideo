import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct AudioLevelTests {
    @Test func levelsMapToGain() {
        #expect(AudioLevel.gain(decibels: 0) == 1)
        #expect(abs(AudioLevel.gain(decibels: 6) - 1.9953) < 0.001)
        #expect(abs(AudioLevel.gain(decibels: -20) - 0.1) < 0.0001)
        #expect(AudioLevel.gain(decibels: AudioLevel.silence) == 0)
        // Out of range clamps: no louder than +6, nothing below silence.
        #expect(AudioLevel.gain(decibels: 40) == AudioLevel.gain(decibels: 6))
        #expect(AudioLevel.gain(decibels: -.infinity) == 0)
    }

    @Test func levelsReadAsDecibels() {
        #expect(AudioLevel.label(0) == "0 dB")
        #expect(AudioLevel.label(3.5) == "+3.5 dB")
        #expect(AudioLevel.label(-12) == "−12 dB")
        #expect(AudioLevel.label(-80) == "−∞ dB")
        #expect(AudioLevel.label(9) == "+6 dB")
    }

    @Test func nestedLayersMultiplyTheirGains() {
        let inner = UUID(), outer = UUID()
        var fade = AnimatedValue(0.0)
        fade.setAnimated(true, at: .zero)
        fade.set(-20, at: CMTime(value: 2, timescale: 1))
        let curves = VolumeCurves([inner: AnimatedValue(6.0), outer: fade])
        // The outer timeline's time is the root's; the inner one starts 5 s in.
        let stages = [
            VolumeStage(layerID: inner, shift: CMTime(value: 5, timescale: 1)),
            VolumeStage(layerID: outer, shift: .zero),
        ]
        #expect(abs(curves.gain(through: stages, at: 1) - AudioLevel.gain(decibels: 6 - 10)) < 0.0001)
        #expect(abs(curves.gain(through: stages, at: 3) - AudioLevel.gain(decibels: 6 - 20)) < 0.0001)
        #expect(curves.gain(through: [VolumeStage(layerID: UUID(), shift: .zero)], at: 1) == 1)
    }

    @Test func detachedSoundKeepsItsVolume() throws {
        var project = EditingProject.empty
        let media = MediaClip(
            name: "Clip", kind: .video, url: nil, duration: CMTime(value: 10, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264", hasAudio: true
        )
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        project.editVolume(of: ids.layerID, in: project.rootTimelineID) { $0.set(-6, at: .zero) }
        let detached = project.detachAudio(in: project.rootTimelineID, layer: ids.layerID)
        let soundID = try #require(detached)
        #expect(project.timeline(id: project.rootTimelineID)?.layer(id: soundID)?.volume.value == -6)
    }

    /// Plays a constant tone through the composition's audio mix the way an
    /// export does, and checks the layer's volume and the meter.
    @Test func theMixAppliesVolumeAboveUnityAndMetersIt() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-level-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 48_000.0
        let samples = [Float](repeating: 0.25, count: Int(rate) * 2)
        do {
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }

        var project = EditingProject.empty
        let media = MediaClip(
            name: "Tone", kind: .audio, url: url, duration: CMTime(value: 2, timescale: 1),
            frameRate: 0, colorSpace: .rec709, codecName: "PCM", hasAudio: true
        )
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        project.editVolume(of: ids.layerID, in: project.rootTimelineID) { $0.set(6, at: .zero) }

        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        let meter = MixLevelMeter()
        let mix = composed.audioMix(curves: VolumeCurves(VolumeCurves.of(project)), meter: meter)

        let reader = try AVAssetReader(asset: composed.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: composed.composition.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = mix
        reader.add(output)
        #expect(reader.startReading())
        var loudest: Float = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            loudest = max(loudest, chunk.map(abs).max() ?? 0)
        }
        let expected = 0.25 * AudioLevel.gain(decibels: 6)
        #expect(abs(loudest - expected) < 0.01)

        let reading = meter.reading(at: 1)
        #expect(abs(reading.rms.x - expected) < 0.01)
        #expect(abs(reading.peak.y - expected) < 0.01)
    }
}
