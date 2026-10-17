import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func video(sound: Bool = false, duration: Double = 4) -> MediaClip {
    MediaClip(
        name: "Clip", kind: .video, url: nil, duration: seconds(duration),
        frameRate: 24, colorSpace: .rec709, codecName: "H.264", hasAudio: sound
    )
}

private func song(duration: Double = 4) -> MediaClip {
    MediaClip(name: "Song", kind: .audio, url: nil, duration: seconds(duration), frameRate: 0, colorSpace: .rec709, codecName: "AAC")
}

private func layers(_ project: EditingProject) -> [TimelineLayer] {
    project.timeline(id: project.rootTimelineID)?.layers ?? []
}

@Suite struct LayerKindTests {
    @Test func placedAssetsGetALayerOfTheirKind() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let pictureResult = project.importClip(video(), intoTimeline: t)
        let picture = try #require(pictureResult)
        let soundResult = project.importClip(song(), intoTimeline: t)
        let sound = try #require(soundResult)
        #expect(layers(project).first { $0.id == picture.layerID }?.kind == .video)
        // Audio goes on music only when the person puts it there.
        #expect(layers(project).first { $0.id == sound.layerID }?.kind == .sound)
    }

    @Test func detachedSoundGoesOnASoundLayer() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let idsResult = project.importClip(video(sound: true), intoTimeline: t)
        let ids = try #require(idsResult)
        let detachedResult = project.detachAudio(in: t, layer: ids.layerID)
        let detached = try #require(detachedResult)
        #expect(layers(project).first { $0.id == detached }?.kind == .sound)
    }

    @Test func clipsOnlyMoveOntoLayersOfAMatchingKind() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let pictureResult = project.importClip(video(), intoTimeline: t)
        let picture = try #require(pictureResult)
        let musicResult = project.importClip(song(), intoTimeline: t)
        let music = try #require(musicResult)

        #expect(project.resolvedMove(ofMoving: music.clipID, in: t, layer: music.layerID, onto: picture.layerID, to: seconds(10)) == nil)
        project.moveClip(music.clipID, in: t, layer: music.layerID, onto: picture.layerID, to: seconds(10))
        #expect(layers(project).first { $0.id == picture.layerID }?.clips.count == 1)

        // Sound and music are both audio, so audio moves between them.
        let sound = TimelineLayer(customName: nil, kind: .sound, clips: [])
        project.timelines[0].layers.append(sound)
        project.moveClip(music.clipID, in: t, layer: music.layerID, onto: sound.id, to: seconds(1))
        #expect(layers(project).first { $0.id == sound.id }?.clips.map(\.id) == [music.clipID])
    }

    @Test func aClipMovedToANewLayerGoesToTheTopAndKeepsItsTime() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let musicResult = project.importClip(song(), intoTimeline: t)
        let music = try #require(musicResult)
        _ = project.importClip(video(), intoTimeline: t)
        project.moveClip(music.clipID, in: t, layer: music.layerID, to: seconds(3))

        #expect(project.moveClipToNewLayer(music.clipID, in: t, layer: music.layerID, kind: .video) == nil)
        let createdResult = project.moveClipToNewLayer(music.clipID, in: t, layer: music.layerID, kind: .sound)
        let created = try #require(createdResult)
        let top = layers(project)[0]
        #expect(top.id == created && top.kind == .sound)
        #expect(top.clips.first?.id == music.clipID && top.clips.first?.startOffset == seconds(3))
    }

    @Test func scenesGoOnANewLayerOfTheChosenKind() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let asset = song()
        project.addMedia(asset)
        let scenes = [SceneRange(start: .zero, end: seconds(2), origin: .auto)]
        let addedResult = project.addScenes(scenes, ofAsset: asset.id, intoTimeline: t, kind: .sound)
        let added = try #require(addedResult)
        #expect(layers(project)[0].id == added.layerID && layers(project)[0].kind == .sound)
        #expect(project.addScenes(scenes, ofAsset: asset.id, intoTimeline: t, kind: .video) == nil)
    }

    @Test func layersSavedWithoutAKindGetOneFromTheirClips() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let pictureResult = project.importClip(video(sound: true), intoTimeline: t)
        let picture = try #require(pictureResult)
        let musicResult = project.importClip(song(), intoTimeline: t)
        let music = try #require(musicResult)
        let detachedResult = project.detachAudio(in: t, layer: picture.layerID)
        let detached = try #require(detachedResult)
        let empty = TimelineLayer(customName: nil, kind: .music, clips: [])
        project.timelines[0].layers.append(empty)

        let ids = Set(layers(project).map(\.id))
        for l in project.timelines[0].layers.indices { project.timelines[0].layers[l].kind = .video }
        project.inferLayerKinds(of: ids)
        let kinds = Dictionary(uniqueKeysWithValues: layers(project).map { ($0.id, $0.kind) })
        #expect(kinds[picture.layerID] == .video)
        #expect(kinds[music.layerID] == .music)
        #expect(kinds[detached] == .sound)
        #expect(kinds[empty.id] == .video)
    }

    @Test func defaultNamesCountWithinEachKind() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        _ = project.importClip(video(), intoTimeline: t)
        _ = project.importClip(song(), intoTimeline: t)
        _ = project.importClip(video(), intoTimeline: t)
        let timeline = try #require(project.timeline(id: t))
        #expect(timeline.layers.map { project.displayName(of: $0, in: timeline) } == ["Video 1", "Sound 1", "Video 2"])
    }

    @Test func layersMoveAmongTheirOwnKind() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        // Top to bottom: video C, music B, video A.
        for asset in [video(), song(), video()] { _ = project.importClip(asset, intoTimeline: t) }
        let ids = layers(project).map(\.id)
        let (videoC, music, videoA) = (ids[0], ids[1], ids[2])

        project.moveLayer(videoA, in: t, by: -1)
        #expect(layers(project).map(\.id) == [videoA, music, videoC])
        project.moveLayer(videoA, in: t, by: -1)
        #expect(layers(project).map(\.id) == [videoA, music, videoC])

        project.moveLayer(videoA, in: t, toPositionInKind: 1)
        #expect(layers(project).map(\.id) == [music, videoC, videoA])
        project.moveLayer(videoA, in: t, toPositionInKind: 0)
        #expect(layers(project).map(\.id) == [music, videoA, videoC])
    }

    @Test func theNewLayerZoneSplitsSoundAboveMusic() {
        let column = CGRect(x: 0, y: 100, width: 150, height: 200)
        #expect(NewLayerHover(audio: false, pointerY: 120, in: column) == NewLayerHover(hovering: .video))
        let top = NewLayerHover(audio: true, pointerY: 150, in: column)
        let bottom = NewLayerHover(audio: true, pointerY: 250, in: column)
        #expect(top.kinds == [.sound, .music] && top.hovered == .sound)
        #expect(bottom.hovered == .music)
    }
}

@Suite struct WaveformTests {
    @Test func theEnvelopeKeepsEachWindowsLoudestSampleScaledToTheLoudest() {
        // 400 samples a second: two samples per window.
        let samples: [Float] = [0.1, -0.4, 0.2, 0.0, -0.8, 0.3]
        let waveform = Waveform.envelope(of: samples, sampleRate: 400)
        #expect(waveform.peaks == [0.5, 0.25, 1.0])
        #expect(waveform.peak(from: 0, to: 0.005) == 0.5)
        #expect(waveform.peak(from: 0.004, to: 0.015) == 1.0)
        #expect(waveform.peak(from: 5, to: 6) == 0)
    }

    @Test func silenceStaysFlat() {
        #expect(Waveform.envelope(of: [0, 0, 0, 0], sampleRate: 400).peaks == [0, 0])
    }

    @Test func stereoKeepsEachChannelScaledTogether() {
        // Interleaved left, right; 400 samples a second, two frames a window.
        let samples: [Float] = [0.5, 0.1, -0.2, 0.0, 0.0, -0.25, 0.1, 0.0]
        let waveform = Waveform.envelope(ofInterleaved: samples, channelCount: 2, sampleRate: 400)
        #expect(waveform.channels == [[1.0, 0.2], [0.2, 0.5]])
        #expect(waveform.peaks == [1.0, 0.5])
        #expect(waveform.peak(from: 0, to: 0.01, channel: 1) == 0.5)
        #expect(waveform.peak(from: 0, to: 0.01, channel: 2) == 0)
    }

    @Test func itFadesInAsLayersGrowTaller() {
        #expect(ClipWaveform.strength(atHeight: 44) == 0)
        #expect(ClipWaveform.strength(atHeight: 80) == 0.5)
        #expect(ClipWaveform.strength(atHeight: 200) == 1)
    }
}
