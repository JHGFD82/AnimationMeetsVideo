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

    @Test func silentVideoHasNothingToDetach() throws {
        var project = EditingProject.empty
        var media = videoWithSound()
        media.hasAudio = false
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        #expect(project.detachAudio(in: project.rootTimelineID, layer: ids.layerID) == nil)
    }
}
