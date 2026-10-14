import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func video(url: URL? = nil, duration: Double = 10) -> MediaClip {
    MediaClip(name: "Clip", kind: .video, url: url, duration: seconds(duration), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
}

private func layers(_ project: EditingProject) -> [TimelineLayer] {
    project.timeline(id: project.rootTimelineID)?.layers ?? []
}

@Suite struct LayerArrangementTests {
    @Test func aLayerMovesToAnyPlaceInTheStack() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        for _ in 0..<3 { project.importClip(video(), intoTimeline: t) }
        let ids = layers(project).map(\.id)
        project.moveLayer(ids[0], in: t, toIndex: 2)
        #expect(layers(project).map(\.id) == [ids[1], ids[2], ids[0]])
        project.moveLayer(ids[0], in: t, toIndex: 0)
        #expect(layers(project).map(\.id) == ids)
    }

    @Test func aClipMovesOntoAnotherLayerAndLeavesItsLayerEmpty() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let firstPlaced = project.importClip(video(duration: 4), intoTimeline: t)
        let secondPlaced = project.importClip(video(duration: 4), intoTimeline: t)
        let first = try #require(firstPlaced), second = try #require(secondPlaced)

        // Straight onto the clip already there: it goes to the nearest free side.
        let preview = project.resolvedStart(ofMoving: second.clipID, in: t, layer: second.layerID, onto: first.layerID, to: seconds(1))
        #expect(preview == seconds(4))
        project.moveClip(second.clipID, in: t, layer: second.layerID, onto: first.layerID, to: seconds(1))

        let target = try #require(layers(project).first { $0.id == first.layerID })
        #expect(target.clips.map(\.id) == [first.clipID, second.clipID])
        #expect(target.clips[1].startOffset == seconds(4))
        // The emptied layer stays so clips can be moved back into it.
        #expect(Set(layers(project).map(\.id)) == [first.layerID, second.layerID])
        #expect(layers(project).first { $0.id == second.layerID }?.clips.isEmpty == true)
    }

    @Test func scenesDroppedOnALayerGoIntoItsGaps() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let asset = video()
        let placed = project.importClip(asset, intoTimeline: t)
        let layer = try #require(placed).layerID
        project.trimClipEnd(try #require(placed).clipID, in: t, layer: layer, to: seconds(2))

        let scenes = [SceneRange(start: seconds(2), end: seconds(3), origin: .auto), SceneRange(start: seconds(5), end: seconds(6), origin: .auto)]
        let added = project.addScenes(scenes, ofAsset: asset.id, intoLayer: layer, in: t, at: seconds(1))
        #expect(added?.count == 2)
        let clips = layers(project)[0].clips
        #expect(clips.map(\.startOffset) == [.zero, seconds(2), seconds(3)])
        #expect(layers(project).count == 1)
    }

    @Test func clipsWhoseSourcesEndBetweenFramesCanMeet() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        // 4.01 s is not a whole number of frames at 24 fps.
        let firstPlaced = project.importClip(video(duration: 4.01), intoTimeline: t)
        let secondPlaced = project.importClip(video(duration: 4.01), intoTimeline: t)
        let first = try #require(firstPlaced), second = try #require(secondPlaced)
        let frame = try #require(project.timeline(id: t)).frameDuration
        let length = layers(project)[1].clips[0].trimmedDuration
        #expect(CMTimeMultiply(frame, multiplier: Int32(length.seconds / frame.seconds)) == length)

        // Dropped onto the first clip, it goes to its end, with no gap.
        project.moveClip(second.clipID, in: t, layer: second.layerID, onto: first.layerID, to: seconds(3))
        let clips = try #require(layers(project).first { $0.id == first.layerID }).clips
        #expect(clips.map(\.id) == [first.clipID, second.clipID])
        #expect(clips[1].startOffset == clips[0].endOffset)
        #expect(project.predecessor(joining: clips[1], among: clips)?.id == first.clipID)
    }
}
