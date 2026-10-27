import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Transitions of sound (the Audio category): which clips take them, the
/// shape they fade with, and the fade heard in the mix.
@Suite struct AudioTransitionTests {
    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    @Test func soundClipsTakeOnlyTransitionsOfSound() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let sound = MediaClip(
            name: "Tone", kind: .audio, url: nil, duration: seconds(4),
            frameRate: 0, colorSpace: .rec709, codecName: "PCM", hasAudio: true
        )
        let video = MediaClip(
            name: "Clip", kind: .video, url: nil, duration: seconds(4),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264", hasAudio: true
        )
        let soundPlaced = project.importClip(sound, intoTimeline: timelineID)
        let videoPlaced = project.importClip(video, intoTimeline: timelineID)
        let soundIDs = try #require(soundPlaced), videoIDs = try #require(videoPlaced)
        func clip(_ ids: (layerID: UUID, clipID: UUID)) throws -> TimelineClip {
            try #require(project.timeline(id: timelineID)?.layer(id: ids.layerID)?.clips.first)
        }
        #expect(project.transitionsTaken(by: try clip(soundIDs)) == .sound)
        #expect(project.transitionsTaken(by: try clip(videoIDs)) == .picture)

        project.setTransition(.crossDissolve, at: .leading, of: soundIDs.clipID, in: timelineID, layer: soundIDs.layerID)
        #expect(try clip(soundIDs).transitionIn == nil)
        project.setTransition(.crossfade, at: .leading, of: videoIDs.clipID, in: timelineID, layer: videoIDs.layerID)
        #expect(try clip(videoIDs).transitionIn == nil)
        project.setTransition(.equalPowerCrossfade, at: .leading, of: soundIDs.clipID, in: timelineID, layer: soundIDs.layerID)
        #expect(try clip(soundIDs).transitionIn?.kind == .equalPowerCrossfade)
    }

    @Test func aTransitionOfSoundFadesWithItsShapeAtAnOpenEnd() throws {
        var project = EditingProject.empty
        var clip = TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: seconds(4))
        clip.transitionIn = ClipTransition(kind: .linearCrossfade, duration: seconds(1), curve: .linear)
        clip.transitionOut = ClipTransition(kind: .crossDissolve, duration: seconds(1), curve: .linear)
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .sound, clips: [clip])]
        let fades = project.audioFades(of: clip, among: [clip]).fades
        #expect(fades.count == 2)
        // Linear: halfway in, half the gain, where a picture's fade is
        // equal power.
        #expect(abs(fades[0].gain(at: 0.5) - 0.5) < 0.001)
        #expect(abs(fades[1].gain(at: 3.5) - Float(cos(Double.pi / 4))) < 0.001)
    }

    @Test func aSoundClipFadesInUnderItsCrossfade() async throws {
        let tone = try AudioMixSupport.tone(amplitude: 0.25, seconds: 2)
        defer { try? FileManager.default.removeItem(at: tone) }
        var (project, clipID, layerID) = try AudioMixSupport.project(playing: tone, seconds: 2)
        project.setTransition(.crossfade, at: .leading, of: clipID, in: project.rootTimelineID, layer: layerID)
        let start = try await AudioMixSupport.loudest(of: project, before: 0.05)
        let middle = try await AudioMixSupport.loudest(of: project, after: 1.2, before: 1.5)
        #expect(start.x < 0.02)
        #expect(middle.x > 0.24)
    }
}
