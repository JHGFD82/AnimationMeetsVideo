import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 48_000) }

@Suite struct BeatMapTests {
    private func section(beats: [MappedBeat], perMeasure: Int = 4) -> BeatSection {
        BeatSection(kind: .consistent, start: .zero, end: seconds(100), beatsPerMeasure: perMeasure, isConfirmed: true, beats: beats)
    }

    @Test func positionsCountOutFromThePinnedBeats() {
        var beats = (0..<10).map { MappedBeat(time: seconds(Double($0))) }
        beats[3] = MappedBeat(time: seconds(3), position: 1, isPinned: true)
        // A second pinned beat that starts the count again.
        beats[7] = MappedBeat(time: seconds(7), position: 3, isPinned: true)
        var section = section(beats: beats)
        section.recountPositions()
        let positions: [Int] = section.beats.map(\.position)
        #expect(positions == [2, 3, 4, 1, 2, 3, 4, 3, 4, 1])
    }

    @Test func withoutPinnedBeatsTheCountStartsWhereAsked() {
        var section = section(beats: (0..<5).map { MappedBeat(time: seconds(Double($0))) }, perMeasure: 3)
        section.recountPositions(firstPosition: 3)
        let positions: [Int] = section.beats.map(\.position)
        #expect(positions == [3, 1, 2, 3, 1])
    }

    @Test func normalizingSortsDropsDoublesAndWrapsPositions() {
        var section = section(beats: [
            MappedBeat(time: seconds(2), position: 9),
            MappedBeat(time: seconds(1)),
            MappedBeat(time: seconds(2), position: 2, isPinned: true),
        ])
        section.normalize()
        let times: [CMTime] = section.beats.map(\.time)
        #expect(times == [seconds(1), seconds(2)])
        #expect(section.beats[1].isPinned)
        #expect(section.beats[1].position == 2)
    }

    @Test func confirmedBeatsReplaceDetectedOnesOnTheTimeline() throws {
        var project = EditingProject.empty
        let asset = MediaClip(
            name: "song.wav", kind: .audio, url: URL(fileURLWithPath: "/dev/null"), duration: seconds(20),
            frameRate: 0, colorSpace: .rec709, codecName: "PCM", hasAudio: true
        )
        project.addMedia(asset)
        project.putOnMusicLayer([asset.id])
        // The clip plays 2...8 s of the song from 10 s on the timeline.
        project.timelines[0].layers[0].clips[0].trimStart = seconds(2)
        project.timelines[0].layers[0].clips[0].trimEnd = seconds(8)
        project.timelines[0].layers[0].clips[0].startOffset = seconds(10)
        let layer = project.timelines[0].layers[0]
        let detected = try BeatTrack(timescale: 1, times: [1, 3, 5], beatsPerMinute: 30)

        let before: [BeatMarker] = project.beatMarkers(in: layer, tracks: [asset.id: detected])
        #expect(before == [BeatMarker(time: CMTime(value: 11, timescale: 1)), BeatMarker(time: CMTime(value: 13, timescale: 1))])

        // Anchors alone don't count until the section is filled.
        var map = BeatMap(sections: [BeatSection(kind: .consistent, start: .zero, end: seconds(20), beats: [
            MappedBeat(time: seconds(2.5), position: 1, isPinned: true), MappedBeat(time: seconds(4.5), position: 1, isPinned: true),
        ])])
        project.clips[0].beatMap = map
        #expect(project.beatMarkers(in: layer, tracks: [asset.id: detected]) == before)

        map.sections[0].isConfirmed = true
        map.sections[0].beats.insert(MappedBeat(time: seconds(1.5), position: 4), at: 0)
        project.clips[0].beatMap = map
        let after: [BeatMarker] = project.beatMarkers(in: project.timelines[0].layers[0], tracks: [asset.id: detected])
        #expect(after == [BeatMarker(time: seconds(10.5), position: 1), BeatMarker(time: seconds(12.5), position: 1)])
        #expect(project.layerHasBeats(layer, tracks: [:]))
    }
}
