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
        let curves = MixCurves(volume: [inner: AnimatedValue(6.0), outer: fade])
        // The outer timeline's time is the root's; the inner one starts 5 s in.
        let stages = [
            MixStage(id: inner, shift: CMTime(value: 5, timescale: 1)),
            MixStage(id: outer, shift: .zero),
        ]
        #expect(abs(curves.gain(through: stages, at: 1) - AudioLevel.gain(decibels: 6 - 10)) < 0.0001)
        #expect(abs(curves.gain(through: stages, at: 3) - AudioLevel.gain(decibels: 6 - 20)) < 0.0001)
        #expect(curves.gain(through: [MixStage(id: UUID(), shift: .zero)], at: 1) == 1)
    }

    @Test func panIsABalance() {
        #expect(AudioPan.gains(0) == SIMD2(1, 1))
        #expect(AudioPan.gains(-100) == SIMD2(1, 0))
        #expect(AudioPan.gains(50) == SIMD2(0.5, 1))
        #expect(AudioPan.gains(400) == SIMD2(0, 1))
        #expect(AudioPan.label(0) == "C")
        #expect(AudioPan.label(-30) == "L 30")
        #expect(AudioPan.label(100) == "R 100")
    }

    @Test func pansStackWithVolumes() {
        let clip = UUID(), layer = UUID()
        let curves = MixCurves(volume: [layer: AnimatedValue(-20.0)], pan: [clip: AnimatedValue(-50.0), layer: AnimatedValue(50.0)])
        let gains = curves.gains(through: [MixStage(id: clip, shift: .zero), MixStage(id: layer, shift: .zero)], at: 0)
        #expect(abs(gains.x - 0.05) < 0.0001)
        #expect(abs(gains.y - 0.05) < 0.0001)
        // The volume alone leaves the pans out.
        #expect(abs(curves.gain(through: [MixStage(id: layer, shift: .zero)], at: 0) - 0.1) < 0.0001)
    }

    @Test func detachedSoundKeepsItsVolume() throws {
        var project = EditingProject.empty
        let media = MediaClip(
            name: "Clip", kind: .video, url: nil, duration: CMTime(value: 10, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264", hasAudio: true
        )
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        project.editClip(ids.clipID, in: project.rootTimelineID) { $0.volume.set(-6, at: .zero) }
        let detached = project.detachAudio(in: project.rootTimelineID, layer: ids.layerID)
        let soundID = try #require(detached)
        let sound = try #require(project.timeline(id: project.rootTimelineID)?.layer(id: soundID)?.clips.first)
        #expect(sound.volume.value == -6)
        #expect(sound.effects.isEmpty)
    }

    /// Every clip's sound is on a track of its own, so a clip's volume
    /// appearing, or crossing 0 dB, doesn't rebuild the player.
    @Test func aClipsVolumeNeverRebuildsThePlayer() throws {
        var project = EditingProject.empty
        let media = MediaClip(
            name: "Tone", kind: .audio, url: nil, duration: CMTime(value: 2, timescale: 1),
            frameRate: 0, colorSpace: .rec709, codecName: "PCM", hasAudio: true
        )
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        let flat = CompositionKey(project: project)
        project.editClip(ids.clipID, in: project.rootTimelineID) { $0.volume.set(-6, at: .zero) }
        let lowered = CompositionKey(project: project)
        project.editClip(ids.clipID, in: project.rootTimelineID) { $0.volume.set(-12, at: .zero) }
        let lowerStill = CompositionKey(project: project)
        #expect(lowered == flat)
        #expect(lowerStill == lowered)
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
        // A second in, so the meter has to place the sound in timeline time.
        project.moveClip(ids.clipID, in: project.rootTimelineID, layer: ids.layerID, to: CMTime(value: 1, timescale: 1))

        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        let meter = MixLevelMeter()
        let mix = composed.audioMix(curves: MixCurves(MixCurves.of(project)), meter: meter)

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

        let reading = meter.reading(at: 2)
        #expect(abs(reading.rms.x - expected) < 0.01)
        #expect(abs(reading.peak.y - expected) < 0.01)
        #expect(meter.reading(at: 0.5).peak.x < 0.001)
    }
}

@Suite struct PanMixTests {
    @Test func aClipsPanTurnsTheOtherSideDown() async throws {
        let url = try AudioMixSupport.tone(channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, clipID, _) = try AudioMixSupport.project(playing: url)
        project.editClip(clipID, in: project.rootTimelineID) { $0.pan.set(-75, at: .zero) }
        let level = try await AudioMixSupport.loudest(of: project)
        #expect(abs(level.x - 0.25) < 0.005)
        #expect(abs(level.y - 0.0625) < 0.005)
    }

    /// A mono track's tap only sees its one channel, so a panned mono clip
    /// plays from a stereo copy of its file, which pans like stereo.
    @Test func aMonoSoundPansFromItsStereoCopy() async throws {
        let url = try AudioMixSupport.tone(channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, _, layerID) = try AudioMixSupport.project(playing: url)
        project.editPan(of: layerID, in: project.rootTimelineID) { $0.set(100, at: .zero) }
        project.editVolume(of: layerID, in: project.rootTimelineID) { $0.set(-6, at: .zero) }
        let level = try await AudioMixSupport.loudest(of: project)
        #expect(level.x < 0.001)
        #expect(abs(level.y - 0.25 * AudioLevel.gain(decibels: -6)) < 0.005)

        // Made once: the same copy serves the next build.
        let copy = try #require(StereoProxies.cacheName(for: url))
        let made = try FileManager.default.attributesOfItem(atPath: StereoProxies.folder.appending(path: copy).path)[.modificationDate] as? Date
        _ = try await AudioMixSupport.loudest(of: project)
        let again = try FileManager.default.attributesOfItem(atPath: StereoProxies.folder.appending(path: copy).path)[.modificationDate] as? Date
        #expect(made == again)
        try? FileManager.default.removeItem(at: StereoProxies.folder.appending(path: copy))
    }

    /// Centered, mono plays from its own file, as before.
    @Test func aCenteredMonoSoundNeedsNoCopy() async throws {
        let url = try AudioMixSupport.tone(channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let (project, _, _) = try AudioMixSupport.project(playing: url)
        let level = try await AudioMixSupport.loudest(of: project)
        #expect(abs(level.x - 0.25) < 0.005 && abs(level.y - 0.25) < 0.005)
        let copy = try #require(StereoProxies.cacheName(for: url))
        #expect(!FileManager.default.fileExists(atPath: StereoProxies.folder.appending(path: copy).path))
    }

    @Test func aChangedFileGetsANewCopy() throws {
        let url = try AudioMixSupport.tone(channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = StereoProxies.cacheName(for: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        #expect(before != nil)
        #expect(StereoProxies.cacheName(for: url) != before)
    }

    /// Moving a pan off center rebuilds the player, to use the copy; moving
    /// it further doesn't.
    @Test func aPanLeavingTheCenterRebuilds() throws {
        let url = URL(filePath: "/dev/null")
        var (project, clipID, layerID) = try AudioMixSupport.project(playing: url)
        let t = project.rootTimelineID
        let centered = CompositionKey(project: project)
        project.editPan(of: layerID, in: t) { $0.set(30, at: .zero) }
        let panned = CompositionKey(project: project)
        project.editPan(of: layerID, in: t) { $0.set(-80, at: .zero) }
        #expect(panned != centered)
        #expect(CompositionKey(project: project) == panned)
        project.editClip(clipID, in: t) { $0.volume.set(-3, at: .zero) }
        let withVolume = CompositionKey(project: project)
        project.editClip(clipID, in: t) { $0.pan.set(20, at: .zero) }
        #expect(CompositionKey(project: project) != withVolume)
    }
}

@Suite struct MeterBallisticsTests {
    @Test func theBarRisesAtOnceAndFallsSteadily() {
        var meter = MeterBallistics()
        meter.update(peak: SIMD2(0.5, 0.25), at: 0)
        #expect(abs(meter.level.x - -6.02) < 0.01)
        #expect(abs(meter.level.y - -12.04) < 0.01)
        meter.update(peak: nil, at: 0.5)
        #expect(abs(meter.level.x - (-6.02 - MeterBallistics.fallRate * 0.5)) < 0.01)
        // The peak mark holds, then falls once the hold is over.
        #expect(abs(meter.held.x - -6.02) < 0.01)
        meter.update(peak: nil, at: 10)
        #expect(meter.level.x == MeterBallistics.floor && meter.held.x == MeterBallistics.floor)
    }

    @Test func clippingLatchesUntilReset() {
        var meter = MeterBallistics()
        meter.update(peak: SIMD2(1.2, 0.1), at: 0)
        meter.update(peak: nil, at: 5)
        #expect(meter.clipped == [true, false])
        meter.resetClips()
        #expect(meter.clipped == [false, false])
    }

    @Test func windowsPlayedAgainDontReadLouder() {
        let meter = MixLevelMeter()
        var samples = [Float](repeating: 0.5, count: 960)
        samples.withUnsafeMutableBufferPointer { buffer in
            let channel = (buffer.baseAddress!, 1)
            for _ in 0..<3 {
                meter.record(left: channel, right: channel, frames: 960, sampleRate: 48_000, start: 1, track: 0)
            }
        }
        #expect(abs(meter.reading(at: 1.01).rms.x - 0.5) < 0.001)
        // A second track as loud adds its power.
        samples.withUnsafeMutableBufferPointer { buffer in
            let channel = (buffer.baseAddress!, 1)
            meter.record(left: channel, right: channel, frames: 960, sampleRate: 48_000, start: 1, track: 1)
        }
        #expect(abs(meter.reading(at: 1.01).rms.x - 0.5 * Float(2).squareRoot()) < 0.001)
        #expect(meter.reading(at: 5) == .silent)
    }
}

@Suite struct MixLevelMeterInvalidTimeTests {
    @Test func aPlayerWithNoValidTimeReadsAsSilent() {
        let meter = MixLevelMeter()
        #expect(meter.reading(at: .nan) == .silent)
        #expect(meter.reading(at: .infinity) == .silent)
    }
}
