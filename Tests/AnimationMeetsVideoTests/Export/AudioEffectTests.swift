import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Sound effects, played through a timeline's audio mix.
@Suite struct AudioEffectTests {
    /// Adds a sound effect of `kind` to the clip and sets its controls.
    private func add(
        _ kind: EffectKind, to clipID: UUID, in project: inout EditingProject, _ values: [ControlKind: Double]
    ) throws {
        let added = project.addEffect(kind, toClip: clipID, in: project.rootTimelineID)
        let effectID = try #require(added)
        project.editEffect(effectID, ofClip: clipID, in: project.rootTimelineID) { effect in
            for (kind, value) in values {
                guard let index = effect.controls.firstIndex(where: { $0.kind == kind }) else { continue }
                effect.controls[index].setComponent(0, to: value, at: .zero)
            }
        }
    }

    /// Adds an EQ to the clip with `band` on and set to `values`.
    private func addEQ(to clipID: UUID, in project: inout EditingProject, _ band: EqualizerBand, _ values: [Double]) throws {
        let added = project.addEffect(.equalizer, toClip: clipID, in: project.rootTimelineID)
        let effectID = try #require(added)
        project.editEffect(effectID, ofClip: clipID, in: project.rootTimelineID) { effect in
            guard let index = effect.controls.firstIndex(where: { $0.kind == band.controlKind }) else { return }
            effect.controls[index].enabled = true
            effect.controls[index].number = AnimatedValue(ComponentValue(values: values))
        }
    }

    @Test func theEQCutsTheTrebleOfAHighTone() async throws {
        let url = try AudioMixSupport.tone(frequency: 12_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, clipID, _) = try AudioMixSupport.project(playing: url)
        let before = try await AudioMixSupport.loudest(of: project, after: 0.2)
        try addEQ(to: clipID, in: &project, .highShelf, [8000, -24, EqualizerBand.flatQ])
        let after = try await AudioMixSupport.loudest(of: project, after: 0.2)
        #expect(abs(before.x - 0.25) < 0.01)
        // Twenty-four decibels is a sixteenth.
        #expect(after.x < 0.25 / 8)
        #expect(after.y < 0.25 / 8)
    }

    @Test func theEQLeavesALowToneAloneWhenOnlyTheTrebleIsCut() async throws {
        let url = try AudioMixSupport.tone(frequency: 200)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, clipID, _) = try AudioMixSupport.project(playing: url)
        try addEQ(to: clipID, in: &project, .highShelf, [8000, -24, EqualizerBand.flatQ])
        let level = try await AudioMixSupport.loudest(of: project, after: 0.2)
        #expect(abs(level.x - 0.25) < 0.02)
    }

    @Test func theCompressorTurnsALoudToneDown() async throws {
        let url = try AudioMixSupport.tone(frequency: 440, amplitude: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, clipID, _) = try AudioMixSupport.project(playing: url)
        try add(.compressor, to: clipID, in: &project, [.threshold: -40, .headroom: 1])
        let level = try await AudioMixSupport.loudest(of: project, after: 0.5)
        #expect(level.x < 0.25)
        #expect(level.x > 0.001)
    }

    @Test func theLimiterHoldsDrivenSoundUnderFullScale() async throws {
        let url = try AudioMixSupport.tone(frequency: 440, amplitude: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, clipID, _) = try AudioMixSupport.project(playing: url)
        // Twelve decibels of drive would take it to 2 without the limiter:
        // it comes out louder than it went in, but under full scale.
        try add(.limiter, to: clipID, in: &project, [.drive: 12])
        let level = try await AudioMixSupport.loudest(of: project, after: 0.2)
        #expect(level.x > 0.55)
        #expect(level.x <= 1.01)
    }

    @Test func aDisabledEffectIsNotHeard() async throws {
        let url = try AudioMixSupport.tone(frequency: 12_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, clipID, _) = try AudioMixSupport.project(playing: url)
        try addEQ(to: clipID, in: &project, .highShelf, [8000, -24, EqualizerBand.flatQ])
        let effectID = try #require(project.clipAndLayer(clipID, in: project.rootTimelineID)?.clip.audioEffects.first?.id)
        project.editEffect(effectID, ofClip: clipID, in: project.rootTimelineID) { $0.enabled = false }
        let level = try await AudioMixSupport.loudest(of: project, after: 0.2)
        #expect(abs(level.x - 0.25) < 0.01)
    }

    // MARK: Model

    @Test func soundEffectsGoInTheSoundsStack() throws {
        let url = URL(filePath: "/dev/null")
        var (project, clipID, _) = try AudioMixSupport.project(playing: url)
        let timelineID = project.rootTimelineID
        // An audio clip has no pictures, so it takes sound effects only.
        #expect(project.addEffect(.color, toClip: clipID, in: timelineID) == nil)
        let eqID = project.addEffect(.equalizer, toClip: clipID, in: timelineID)
        let eq = try #require(eqID)
        let limiterID = project.addEffect(.limiter, toClip: clipID, in: timelineID, at: 0)
        let limiter = try #require(limiterID)
        let clip = try #require(project.clipAndLayer(clipID, in: timelineID)?.clip)
        #expect(clip.effects.isEmpty)
        #expect(clip.audioEffects.map(\.id) == [limiter, eq])
        #expect(clip.hasOwnMix)

        project.moveEffect(limiter, ofClip: clipID, in: timelineID, toIndex: 1)
        let copyID = project.duplicateEffect(eq, ofClip: clipID, in: timelineID)
        let copy = try #require(copyID)
        let moved = try #require(project.clipAndLayer(clipID, in: timelineID)?.clip)
        #expect(moved.audioEffects.map(\.id) == [eq, copy, limiter])
        #expect(moved.audioEffects[1].displayName == "EQ 2")
        project.removeEffect(copy, fromClip: clipID, in: timelineID)
        #expect(project.clipAndLayer(clipID, in: timelineID)?.clip.audioEffects.count == 2)
    }

    @Test func pastingSendsEachEffectToItsOwnStack() throws {
        var project = EditingProject.empty
        let media = MediaClip(
            name: "Clip", kind: .video, url: nil, duration: CMTime(value: 10, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264", hasAudio: true
        )
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        let timelineID = project.rootTimelineID
        project.addEffect(.color, toClip: ids.clipID, in: timelineID)
        project.addEffect(.compressor, toClip: ids.clipID, in: timelineID)
        let bundle = try #require(project.bundle(ofEffects: nil, fromClip: ids.clipID, in: timelineID))
        #expect(bundle.effects.map(\.effect.kind) == [.color, .compressor])
        project.paste(bundle, ontoClip: ids.clipID, in: timelineID)
        let clip = try #require(project.clipAndLayer(ids.clipID, in: timelineID)?.clip)
        #expect(clip.effects.map(\.kind) == [.color, .color])
        #expect(clip.audioEffects.map(\.kind) == [.compressor, .compressor])

        // Detaching the sound takes its effects with it.
        let detached = project.detachAudio(in: timelineID, layer: ids.layerID)
        let soundLayer = try #require(detached)
        #expect(project.clipAndLayer(ids.clipID, in: timelineID)?.clip.audioEffects.isEmpty == true)
        #expect(project.timeline(id: timelineID)?.layer(id: soundLayer)?.clips.first?.audioEffects.count == 2)
    }

    @Test func settingsAreHeardWithoutRebuildingButNewEffectsRebuild() throws {
        let url = URL(filePath: "/dev/null")
        var (project, clipID, _) = try AudioMixSupport.project(playing: url)
        let timelineID = project.rootTimelineID
        let eqID = project.addEffect(.equalizer, toClip: clipID, in: timelineID)
        let eq = try #require(eqID)
        let before = CompositionKey(project: project)
        project.editEffect(eq, ofClip: clipID, in: timelineID) { effect in
            if let index = effect.controls.firstIndex(where: { $0.kind == .eqBell2 }) {
                effect.controls[index].enabled = true
                effect.controls[index].setComponent(1, to: 6, at: .zero)
            }
            effect.name = "Brighter"
        }
        #expect(CompositionKey(project: project) == before)
        project.addEffect(.limiter, toClip: clipID, in: timelineID)
        #expect(CompositionKey(project: project) != before)
    }

    @Test func dynamicsControlsAreNeverDimmedAtTheirDefaults() {
        let compressor = Effect(kind: .compressor)
        #expect(!compressor.isNoOp)
        #expect(compressor.controls.allSatisfy { !$0.isNoOp })
        #expect(Effect(kind: .equalizer).isNoOp)
    }
}

/// Sound effects that hold sound back are made up for, so the sound is
/// heard where it was placed.
@Suite struct EffectLatencyTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 48_000) }

    @Test func soundIsPlacedEarlierAndTrimmedAtTheStart() throws {
        let piece = (file: CMTimeRange(start: seconds(2), duration: seconds(1)), at: seconds(0.05), length: seconds(1))
        let later = try #require(CompositionExporter.moved(piece, earlierBy: seconds(0.02)))
        #expect(abs(later.at.seconds - 0.03) < 1e-6 && later.file == piece.file)
        // Before the timeline's start it's cut off, from the file too.
        let cut = try #require(CompositionExporter.moved(piece, earlierBy: seconds(0.08)))
        #expect(cut.at == .zero)
        #expect(abs(cut.file.start.seconds - 2.03) < 1e-6 && abs(cut.length.seconds - 0.97) < 1e-6)
        // Retimed at half speed: the file is cut by half as much.
        let slow = (file: CMTimeRange(start: seconds(2), duration: seconds(1)), at: seconds(0), length: seconds(2))
        let slowCut = try #require(CompositionExporter.moved(slow, earlierBy: seconds(0.1)))
        #expect(abs(slowCut.file.start.seconds - 2.05) < 1e-6)
        #expect(CompositionExporter.moved((piece.file, .zero, seconds(0.01)), earlierBy: seconds(0.02)) == nil)
    }

    @Test func voiceIsolationRendersAWholeMix() async throws {
        let url = try AudioMixSupport.tone(frequency: 440, amplitude: 0.25, seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, clipID, _) = try AudioMixSupport.project(playing: url, seconds: 2)
        let added = project.addEffect(.voiceIsolation, toClip: clipID, in: project.rootTimelineID)
        #expect(added != nil)
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        #expect(composed.audioTracks.first.map { $0.latency > 0.03 } ?? false)
        let rendered = FileManager.default.temporaryDirectory.appending(path: "amv-isolate-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: rendered) }
        try await LoudnessMastering.render(composed, curves: MixCurves(MixCurves.of(project)), limiting: false, to: rendered)
        let file = try AVAudioFile(forReading: rendered)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 2) < 0.01)
    }

    @Test func theDelayingUnitsAreKnown() {
        #expect(AudioEffectUnit.latency(of: .equalizer) == 0)
        #expect(AudioEffectUnit.latency(of: .compressor) > 0.001)
        #expect(AudioEffectUnit.latency(of: .voiceIsolation) > 0.03)
        #expect(AudioEffectUnit.latency(of: .color) == 0)
    }

    /// Where the loudest sample of the mix is, in seconds.
    private func loudestMoment(of project: EditingProject) async throws -> Double {
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        let rendered = FileManager.default.temporaryDirectory.appending(path: "amv-latency-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: rendered) }
        try await LoudnessMastering.render(composed, curves: MixCurves(MixCurves.of(project)), limiting: false, to: rendered)
        let file = try AVAudioFile(forReading: rendered)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        var best = (index: 0, level: Float(0))
        for index in 0..<Int(buffer.frameLength) where abs(buffer.floatChannelData![0][index]) > best.level {
            best = (index, abs(buffer.floatChannelData![0][index]))
        }
        return Double(best.index) / file.processingFormat.sampleRate
    }

    @Test func aClickThroughTheCompressorLandsWhereItWasPlaced() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-click-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        for channel in 0..<2 {
            buffer.floatChannelData![channel].update(repeating: 0, count: 96_000)
            // A short click at 1 s.
            for index in 48_000..<48_024 { buffer.floatChannelData![channel][index] = 0.5 }
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        var (project, clipID, _) = try AudioMixSupport.project(playing: url, seconds: 2)
        let added = project.addEffect(.compressor, toClip: clipID, in: project.rootTimelineID)
        let effectID = try #require(added)
        // A gentle setting, so the click comes through.
        project.editEffect(effectID, ofClip: clipID, in: project.rootTimelineID) { effect in
            if let index = effect.controls.firstIndex(where: { $0.kind == .threshold }) {
                effect.controls[index].setComponent(0, to: 0, at: .zero)
            }
        }
        let moment = try await loudestMoment(of: project)
        #expect(abs(moment - 1) < 0.002)
    }
}

/// Sound effects on Sound and Music layers.
@Suite struct LayerSoundEffectTests {
    /// Adds a sound effect of `kind` to the layer, with `change` made to it.
    private func add(_ kind: EffectKind, toLayer layerID: UUID, in project: inout EditingProject, _ change: (inout Effect) -> Void) throws {
        let added = project.addEffect(kind, toLayer: layerID, in: project.rootTimelineID)
        let effectID = try #require(added)
        project.editEffect(effectID, ofLayer: layerID, in: project.rootTimelineID, change)
    }

    @Test func aLayersEQCutsEverythingOnIt() async throws {
        let url = try AudioMixSupport.tone(frequency: 12_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, _, layerID) = try AudioMixSupport.project(playing: url)
        try add(.equalizer, toLayer: layerID, in: &project) { effect in
            guard let index = effect.controls.firstIndex(where: { $0.kind == .eqHighShelf }) else { return }
            effect.controls[index].enabled = true
            effect.controls[index].number = AnimatedValue(ComponentValue(values: [8000, -24, EqualizerBand.flatQ]))
        }
        let level = try await AudioMixSupport.loudest(of: project, after: 0.2)
        #expect(level.x < 0.25 / 8)
    }

    @Test func aClipsVolumeComesBeforeItsLayersEffects() async throws {
        let url = try AudioMixSupport.tone(frequency: 440)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, clipID, layerID) = try AudioMixSupport.project(playing: url)
        // The clip at a quarter, then 24 dB of drive into the layer's
        // limiter: as a channel strip, the limiter hears the quieter sound
        // and drives it up to full scale. The other way round, the clip's
        // volume would bring the limited sound back down to about 0.25.
        project.editClip(clipID, in: project.rootTimelineID) { $0.volume = AnimatedValue(-12) }
        try add(.limiter, toLayer: layerID, in: &project) { effect in
            guard let index = effect.controls.firstIndex(where: { $0.kind == .drive }) else { return }
            effect.controls[index].setComponent(0, to: 24, at: .zero)
        }
        let level = try await AudioMixSupport.loudest(of: project, after: 0.2)
        #expect(level.x > 0.55)
        #expect(level.x <= 1.01)
    }

    @Test func onlyAudioLayersTakeSoundEffects() throws {
        var (project, _, layerID) = try AudioMixSupport.project(playing: URL(filePath: "/dev/null"))
        let timelineID = project.rootTimelineID
        #expect(project.addEffect(.color, toLayer: layerID, in: timelineID) == nil)
        let first = try #require(project.addEffect(.equalizer, toLayer: layerID, in: timelineID))
        let second = try #require(project.addEffect(.compressor, toLayer: layerID, in: timelineID))
        project.moveEffect(second, ofLayer: layerID, in: timelineID, toIndex: 0)
        #expect(project.timeline(id: timelineID)?.layer(id: layerID)?.audioEffects.map(\.id) == [second, first])
        project.removeEffect(first, fromLayer: layerID, in: timelineID)
        #expect(project.timeline(id: timelineID)?.layer(id: layerID)?.audioEffects.map(\.id) == [second])
    }

    @Test func addingALayerEffectRebuildsButChangingItDoesNot() throws {
        var (project, _, layerID) = try AudioMixSupport.project(playing: URL(filePath: "/dev/null"))
        let timelineID = project.rootTimelineID
        let before = CompositionKey(project: project)
        let eq = try #require(project.addEffect(.equalizer, toLayer: layerID, in: timelineID))
        let added = CompositionKey(project: project)
        #expect(added != before)
        project.editEffect(eq, ofLayer: layerID, in: timelineID) { $0.controls[3].enabled = true }
        #expect(CompositionKey(project: project) == added)
        #expect(MixCurves.of(project).effects[layerID]?.map(\.id) == [eq])
    }
}
