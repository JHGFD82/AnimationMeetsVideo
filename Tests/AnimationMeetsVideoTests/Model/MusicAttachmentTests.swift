import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func song(_ duration: Double = 60) -> MediaClip {
    MediaClip(name: "Song", kind: .audio, url: nil, duration: seconds(duration), frameRate: 0, colorSpace: .rec709, codecName: "AAC")
}

private func footage(_ duration: Double = 20) -> MediaClip {
    MediaClip(name: "Shot", kind: .video, url: nil, duration: seconds(duration), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
}

/// A project with songs on Music layers and footage on a video layer, edited
/// as the editor does: each edit, then the clips following the music.
private struct Edit {
    var project = EditingProject.empty
    var timelineID: UUID { project.rootTimelineID }
    var videoLayerID = UUID()

    init() {
        project.timelines[0].layers.append(TimelineLayer(id: videoLayerID, customName: nil, kind: .video, clips: []))
    }

    /// Puts a song on a new Music layer, at the bottom.
    @discardableResult
    mutating func addSong(at start: Double, trimStart: Double = 0, length: Double = 30) -> (layerID: UUID, clipID: UUID) {
        let asset = song()
        project.addMedia(asset)
        var clip = TimelineClip(source: .media(asset.id), startOffset: seconds(start), trimStart: seconds(trimStart), trimEnd: seconds(trimStart + length))
        clip.streams = .audio
        let layer = TimelineLayer(customName: nil, kind: .music, clips: [clip])
        apply { $0.timelines[0].layers.append(layer) }
        return (layer.id, clip.id)
    }

    /// Puts footage on the video layer.
    @discardableResult
    mutating func addShot(at start: Double, length: Double = 4) -> UUID {
        let asset = footage()
        project.addMedia(asset)
        let clip = TimelineClip(source: .media(asset.id), startOffset: seconds(start), trimStart: .zero, trimEnd: seconds(length))
        let layerID = videoLayerID
        apply { project in
            let l = project.timelines[0].layers.firstIndex { $0.id == layerID }!
            project.timelines[0].layers[l].clips.append(clip)
            project.timelines[0].layers[l].clips.sort { $0.startOffset < $1.startOffset }
        }
        return clip.id
    }

    mutating func apply(_ change: (inout EditingProject) -> Void) {
        let before = project
        change(&project)
        project.followMusic(from: before)
    }

    func clip(_ id: UUID) -> TimelineClip {
        project.timeline(id: timelineID)!.layers.flatMap(\.clips).first { $0.id == id }!
    }

    func start(_ id: UUID) -> Double { clip(id).startOffset.seconds }
}

@Suite struct MusicAttachmentTests {
    @Test func footageOverASongAttachesAtItsFirstFrame() {
        var edit = Edit()
        let song = edit.addSong(at: 2, trimStart: 10)
        let shot = edit.addShot(at: 5)
        let music = edit.clip(shot).music
        #expect(music?.songClipID == song.clipID)
        // 5 s on the timeline is 3 s into the clip, 13 s into the song.
        #expect(music?.songTime == seconds(13))
        #expect(music?.frame == nil)
    }

    @Test func footageWithNoSongUnderItWaitsUntilOneIsPut() {
        var edit = Edit()
        let shot = edit.addShot(at: 5)
        #expect(edit.clip(shot).music == nil)
        edit.addSong(at: 0)
        #expect(edit.clip(shot).music?.songTime == seconds(5))
    }

    @Test func movingTheSongMovesItsFootage() {
        var edit = Edit()
        let t = edit.timelineID
        let song = edit.addSong(at: 0)
        let shot = edit.addShot(at: 5)
        edit.apply { $0.moveClip(song.clipID, in: t, layer: song.layerID, to: seconds(3)) }
        #expect(edit.start(shot) == 8)
        edit.apply { $0.moveClip(song.clipID, in: t, layer: song.layerID, to: seconds(1)) }
        #expect(edit.start(shot) == 6)
    }

    @Test func footageFollowsToTheNearestFrame() {
        var edit = Edit()
        let t = edit.timelineID
        let song = edit.addSong(at: 0)
        let shot = edit.addShot(at: 5)
        // A song moves by samples; the footage stays on the 24 fps grid.
        edit.apply { $0.moveClip(song.clipID, in: t, layer: song.layerID, to: CMTime(value: 900, timescale: 48_000)) }
        #expect(edit.clip(shot).startOffset == CMTime(value: 5 * 24 + 0, timescale: 24))
        edit.apply { $0.moveClip(song.clipID, in: t, layer: song.layerID, to: CMTime(value: 1500, timescale: 48_000)) }
        #expect(edit.clip(shot).startOffset == CMTime(value: 5 * 24 + 1, timescale: 24))
        // Following again doesn't add up rounding: back to the start, back
        // where it began.
        edit.apply { $0.moveClip(song.clipID, in: t, layer: song.layerID, to: .zero) }
        #expect(edit.start(shot) == 5)
    }

    @Test func movingFootageAttachesItWhereItLands() {
        var edit = Edit()
        let t = edit.timelineID, v = edit.videoLayerID
        let song = edit.addSong(at: 0)
        let shot = edit.addShot(at: 5)
        edit.apply { $0.moveClip(shot, in: t, layer: v, to: seconds(10)) }
        #expect(edit.clip(shot).music?.songTime == seconds(10))
        edit.apply { $0.moveClip(song.clipID, in: t, layer: song.layerID, to: seconds(2)) }
        #expect(edit.start(shot) == 12)
    }

    @Test func movingSongAndFootageTogetherKeepsBothWhereTheyWerePut() {
        var edit = Edit()
        let t = edit.timelineID, v = edit.videoLayerID
        let song = edit.addSong(at: 0)
        let shot = edit.addShot(at: 5)
        edit.apply { project in
            project.moveClip(song.clipID, in: t, layer: song.layerID, to: seconds(2))
            project.moveClip(shot, in: t, layer: v, to: seconds(20))
        }
        #expect(edit.start(shot) == 20)
        #expect(edit.clip(shot).music?.songTime == seconds(18))
    }

    @Test func footageSetNotToFollowStaysPut() {
        var edit = Edit()
        let t = edit.timelineID
        let song = edit.addSong(at: 0)
        let shot = edit.addShot(at: 5)
        edit.apply { $0.editClip(shot, in: t) { $0.followsMusic = false } }
        #expect(edit.clip(shot).music == nil)
        edit.apply { $0.moveClip(song.clipID, in: t, layer: song.layerID, to: seconds(3)) }
        #expect(edit.start(shot) == 5)
        // Following again attaches it where it now sits.
        edit.apply { $0.editClip(shot, in: t) { $0.followsMusic = true } }
        #expect(edit.clip(shot).music?.songTime == seconds(2))
    }

    @Test func aCutSongsPiecesEachCarryTheirOwnFootage() throws {
        var edit = Edit()
        let t = edit.timelineID
        let song = edit.addSong(at: 0)
        let early = edit.addShot(at: 2)
        let late = edit.addShot(at: 12)
        edit.apply { $0.split(song.clipID, in: t, layer: song.layerID, atTimelineTime: seconds(10)) }
        let pieces = try #require(edit.project.timeline(id: t)?.layer(id: song.layerID)?.clips)
        #expect(pieces.count == 2)
        #expect(edit.start(early) == 2 && edit.start(late) == 12)
        // The second piece moves later, taking only its footage along.
        edit.apply { $0.moveClip(pieces[1].id, in: t, layer: song.layerID, to: seconds(15)) }
        #expect(edit.start(early) == 2)
        #expect(edit.start(late) == 17)
        #expect(edit.clip(late).music?.songClipID == pieces[1].id)
    }

    @Test func theFirstMusicLayerWithASongThereIsTheSong() {
        var edit = Edit()
        let upper = edit.addSong(at: 10, length: 10)
        let lower = edit.addSong(at: 0, length: 40)
        let before = edit.addShot(at: 5)
        let during = edit.addShot(at: 12)
        #expect(edit.clip(before).music?.songClipID == lower.clipID)
        #expect(edit.clip(during).music?.songClipID == upper.clipID)
    }

    @Test func attachingAtThePlayheadTiesThatFrame() {
        var edit = Edit()
        let t = edit.timelineID
        let first = edit.addSong(at: 0, length: 10)
        let second = edit.addSong(at: 10, length: 20)
        // Straddling the two songs, the shot starts over the first.
        let shot = edit.addShot(at: 8, length: 6)
        #expect(edit.clip(shot).music?.songClipID == first.clipID)
        edit.apply { $0.attachToMusic(shot, in: t, at: seconds(12)) }
        let music = edit.clip(shot).music
        #expect(music?.songClipID == second.clipID)
        #expect(music?.frame == seconds(4))
        #expect(music?.songTime == seconds(2))
        // Now it follows the second song, not the first.
        edit.apply { $0.moveClip(first.clipID, in: t, layer: first.layerID, to: seconds(40)) }
        #expect(edit.start(shot) == 8)
        edit.apply { $0.moveClip(second.clipID, in: t, layer: second.layerID, to: seconds(11)) }
        #expect(edit.start(shot) == 9)
    }

    @Test func footageInTheWayIsPushedLater() {
        var edit = Edit()
        let t = edit.timelineID
        let song = edit.addSong(at: 0, length: 10)
        let shot = edit.addShot(at: 5, length: 4)
        // No song under this one, so it stays put until something moves it.
        let loose = edit.addShot(at: 12, length: 4)
        #expect(edit.clip(loose).music == nil)
        edit.apply { $0.moveClip(song.clipID, in: t, layer: song.layerID, to: seconds(5)) }
        #expect(edit.start(shot) == 10)
        // The song doesn't give way; the footage it would cover moves on.
        #expect(edit.start(loose) == 14)
    }

    @Test func musicLayersAreNeverAttached() {
        var edit = Edit()
        let first = edit.addSong(at: 0)
        edit.addSong(at: 0)
        #expect(edit.clip(first.clipID).music == nil)
    }
}
