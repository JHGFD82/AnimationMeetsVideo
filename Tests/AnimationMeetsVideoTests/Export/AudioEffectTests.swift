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

    @Test func theEQCutsTheTrebleOfAHighTone() async throws {
        let url = try AudioMixSupport.tone(frequency: 12_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, clipID, _) = try AudioMixSupport.project(playing: url)
        let before = try await AudioMixSupport.loudest(of: project, after: 0.2)
        try add(.equalizer, to: clipID, in: &project, [.treble: -24])
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
        try add(.equalizer, to: clipID, in: &project, [.treble: -24])
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
        try add(.equalizer, to: clipID, in: &project, [.treble: -24])
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
            effect.controls[1].setComponent(0, to: 6, at: .zero)
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
