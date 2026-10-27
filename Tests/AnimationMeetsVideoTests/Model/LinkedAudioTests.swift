import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func videoWithSound(url: URL? = nil, duration: Double = 10) -> MediaClip {
    MediaClip(
        name: "Clip", kind: .video, url: url, duration: seconds(duration),
        frameRate: 24, colorSpace: .rec709, codecName: "H.264", hasAudio: true
    )
}

@Suite struct DetachAudioTests {
    @Test func detachingMovesTheSoundToANewLayerBelow() throws {
        var project = EditingProject.empty
        let imported = project.importClip(videoWithSound(), intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        let timelineID = project.rootTimelineID
        project.moveClip(ids.clipID, in: timelineID, layer: ids.layerID, to: seconds(2))
        let video = try #require(project.timeline(id: timelineID)?.layer(id: ids.layerID)?.clips.first)
        #expect(project.hasLinkedAudio(video))

        let detached = project.detachAudio(in: timelineID, layer: ids.layerID)
        let audioLayerID = try #require(detached)

        let layers = try #require(project.timeline(id: timelineID)?.layers)
        #expect(layers.map(\.id) == [ids.layerID, audioLayerID])
        let picture = layers[0].clips[0]
        let sound = layers[1].clips[0]
        #expect(picture.streams == .video)
        #expect(sound.streams == .audio)
        #expect(sound.id != picture.id)
        #expect(sound.startOffset == picture.startOffset && sound.trimStart == picture.trimStart && sound.trimEnd == picture.trimEnd)
        #expect(project.playsVideo(picture) && !project.playsAudio(picture))
        #expect(project.playsAudio(sound) && !project.playsVideo(sound))
        #expect(!project.hasEffectStack(sound))
        #expect(!project.isFrameLocked(sound))
        // Nothing left to detach.
        #expect(project.detachAudio(in: timelineID, layer: ids.layerID) == nil)
    }

    /// A nested timeline playing a tone, embedded in Main and detached: its
    /// picture stays, its sound moves below and plays once, as loud.
    @Test func aNestedTimelinesSoundDetaches() async throws {
        let tone = try AudioMixSupport.tone(amplitude: 0.25, seconds: 1)
        defer { try? FileManager.default.removeItem(at: tone) }
        var (project, _, _) = try AudioMixSupport.project(playing: tone)
        let inner = project.rootTimelineID
        let main = project.addTimeline(name: "Main", frameSize: CGSize(width: 64, height: 36), frameRate: 24, colorSpace: .rec709)
        project.rootTimelineID = main
        let embedded = project.embedTimeline(inner, intoTimeline: main)
        let layerID = try #require(embedded?.layerID)
        let nested = try #require(project.timeline(id: main)?.layer(id: layerID)?.clips.first)
        #expect(project.canDetachAudio(nested))
        #expect(!project.hasLinkedAudio(nested))
        let before = try await AudioMixSupport.loudest(of: project)

        let detached = project.detachAudio(in: main, layer: layerID)
        let soundLayerID = try #require(detached)
        let layers = try #require(project.timeline(id: main)?.layers)
        #expect(layers.map(\.id) == [layerID, soundLayerID])
        let picture = layers[0].clips[0], sound = layers[1].clips[0]
        #expect(picture.source == .timeline(inner) && sound.source == .timeline(inner))
        #expect(project.playsVideo(picture) && !project.playsAudio(picture))
        #expect(project.playsAudio(sound) && !project.playsVideo(sound))
        #expect(!project.canDetachAudio(picture) && !project.canDetachAudio(sound))

        // Played once: had the picture clip kept its sound, twice as loud.
        let after = try await AudioMixSupport.loudest(of: project)
        #expect(abs(after.x - before.x) < 0.01 && before.x > 0.2)
    }

    @Test func aNestedTimelineWithoutSoundHasNothingToDetach() throws {
        var project = EditingProject.empty
        let inner = project.rootTimelineID
        _ = project.addShapeLayer(.rectangle, to: inner, duration: seconds(2))
        let main = project.addTimeline(name: "Main", frameSize: CGSize(width: 64, height: 36), frameRate: 24, colorSpace: .rec709)
        let embedded = project.embedTimeline(inner, intoTimeline: main)
        let clip = try #require(embedded.flatMap { project.timeline(id: main)?.layer(id: $0.layerID)?.clips.first })
        #expect(!project.canDetachAudio(clip))
    }

    @Test func detachingMutedSoundPlaysItOnTheSoundLayer() throws {
        var project = EditingProject.empty
        let imported = project.importClip(videoWithSound(), intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        let timelineID = project.rootTimelineID
        project.editClip(ids.clipID, in: timelineID) {
            $0.soundMuted = true
            $0.volume.set(-6, at: .zero)
        }
        // Muted, the sound is still the clip's to detach.
        let video = try #require(project.clipAndLayer(ids.clipID, in: timelineID)?.clip)
        #expect(project.hasLinkedAudio(video))

        let detached = project.detachAudio(in: timelineID, layer: ids.layerID)
        let soundLayerID = try #require(detached)
        let soundLayer = try #require(project.timeline(id: timelineID)?.layer(id: soundLayerID))
        #expect(soundLayer.kind == .sound)
        #expect(!soundLayer.clips[0].soundMuted)
        #expect(soundLayer.clips[0].volume.value == -6)
        #expect(project.clipAndLayer(ids.clipID, in: timelineID)?.clip.soundMuted == false)
    }

    @Test func silentVideoHasNothingToDetach() throws {
        var project = EditingProject.empty
        var media = videoWithSound()
        media.hasAudio = false
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        #expect(project.detachAudio(in: project.rootTimelineID, layer: ids.layerID) == nil)
    }
}
