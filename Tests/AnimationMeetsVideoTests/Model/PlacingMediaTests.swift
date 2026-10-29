import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct PlacingMediaTests {
    private func t(_ frame: Int64) -> CMTime { CMTime(value: frame, timescale: 24) }

    private func video(_ name: String) -> MediaClip {
        MediaClip(name: name, kind: .video, url: nil, duration: t(240), frameRate: 24, colorSpace: .rec709, codecName: "Test")
    }

    private func audio(_ name: String) -> MediaClip {
        MediaClip(name: name, kind: .audio, url: nil, duration: t(240), frameRate: 0, colorSpace: .rec709, codecName: "Test", hasAudio: true)
    }

    /// A timeline dragged from the browser goes down embedded, on a new
    /// video layer or onto a layer at the drop time, as clips do; never into
    /// itself or a timeline it is drawn into.
    @Test func aTimelineDroppedOnAnotherIsEmbedded() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let scene = project.addTimeline(name: "Scene", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        let a = video("A")
        project.clips = [a]
        _ = project.addPieces([MediaPiece(assetID: a.id, start: t(0), end: t(240))], intoTimeline: scene)
        let piece = MediaPiece.timeline(scene, from: t(24), to: t(72))

        let added = project.addPieces([piece], intoTimeline: main, at: t(12))
        let result = try #require(added)
        let layer = try #require(project.timeline(id: main)?.layer(id: result.layerID))
        #expect(layer.kind == .video)
        let clip = try #require(layer.clips.first)
        #expect(clip.source == .timeline(scene))
        #expect(clip.trimStart == t(24) && clip.trimEnd == t(72) && clip.startOffset == t(12))

        // Onto that layer, after the clip already there.
        let more = project.addPieces([piece], intoLayer: result.layerID, in: main, at: t(60))
        #expect(more?.count == 1)
        #expect(project.timeline(id: main)?.layer(id: result.layerID)?.clips.count == 2)

        // Not into itself, nor into Scene now that Main holds it.
        let ownPiece = MediaPiece.timeline(main, from: .zero, to: t(24))
        let intoItself = project.addPieces([ownPiece], intoTimeline: main)
        let intoChild = project.addPieces([ownPiece], intoTimeline: scene)
        #expect(intoItself == nil && intoChild == nil)
    }

    /// Timelines dragged onto another in the browser go in only when every
    /// one of them can: one that would hold the target spoils the drop.
    @Test func aDropOntoATimelineTakesAllOfItOrNothing() {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let size = CGSize(width: 1920, height: 1080)
        let verse = project.addTimeline(name: "Verse", frameSize: size, frameRate: 24, colorSpace: .rec709)
        let chorus = project.addTimeline(name: "Chorus", frameSize: size, frameRate: 24, colorSpace: .rec709)
        let a = video("A")
        project.clips = [a]
        _ = project.addPieces([MediaPiece(assetID: a.id, start: t(0), end: t(48))], intoTimeline: verse)
        _ = project.addPieces([MediaPiece(assetID: a.id, start: t(0), end: t(48))], intoTimeline: chorus)
        _ = project.addPieces([MediaPiece(assetID: a.id, start: t(0), end: t(48))], intoTimeline: main)
        _ = project.embedTimeline(chorus, intoTimeline: main)
        let whole = { (id: UUID) in MediaPiece.timeline(id, from: .zero, to: project.timeline(id: id)!.duration) }

        #expect(project.canPlaceAll([whole(verse)], in: chorus))
        #expect(!project.canPlaceAll([], in: chorus))
        // Main holds Chorus, so it can't go inside it; nor can Verse with it.
        #expect(!project.canPlaceAll([whole(verse), whole(main)], in: chorus))
        #expect(!project.canPlaceAll([whole(chorus)], in: chorus))
    }

    @Test func piecesOfSeveralAssetsGoBackToBackOnOneLayerInTheOrderGiven() throws {
        var project = EditingProject.empty
        let a = video("A"), b = video("B")
        project.clips = [a, b]
        let pieces = [
            MediaPiece(assetID: b.id, start: t(0), end: t(24)),
            MediaPiece(assetID: a.id, start: t(48), end: t(60)),
        ]
        let added = project.addPieces(pieces, intoTimeline: project.rootTimelineID)
        let result = try #require(added)

        let layers = project.timelines[0].layers
        #expect(layers.count == 1)
        #expect(layers[0].id == result.layerID)
        #expect(layers[0].clips.map(\.source) == [.media(b.id), .media(a.id)])
        #expect(layers[0].clips.map(\.startOffset) == [t(0), t(24)])
        #expect(layers[0].clips.map(\.trimStart) == [t(0), t(48)])
    }

    @Test func soundAndPicturesTogetherLandAsOneRunAcrossTwoLayers() throws {
        var project = EditingProject.empty
        let v = video("V"), s = audio("S")
        project.clips = [v, s]
        let pieces = [
            MediaPiece(assetID: v.id, start: t(0), end: t(24)),
            MediaPiece(assetID: s.id, start: t(0), end: t(12)),
            MediaPiece(assetID: v.id, start: t(100), end: t(112)),
        ]
        let added = project.addPieces(pieces, intoTimeline: project.rootTimelineID)
        let result = try #require(added)

        let layers = project.timelines[0].layers
        #expect(layers.count == 2)
        let pictures = try #require(layers.first { $0.kind == .video })
        let sound = try #require(layers.first { $0.kind != .video })
        #expect(result.layerID == pictures.id)
        // Each piece keeps its place in the run: 0, 24, then 36.
        #expect(pictures.clips.map(\.startOffset) == [t(0), t(36)])
        #expect(sound.clips.map(\.startOffset) == [t(24)])
        #expect(result.clipIDs.count == 3)
    }

    @Test func aKindThatCantTakeEveryPieceAddsNothing() {
        var project = EditingProject.empty
        let v = video("V"), s = audio("S")
        project.clips = [v, s]
        let pieces = [MediaPiece(assetID: v.id, start: t(0), end: t(24)), MediaPiece(assetID: s.id, start: t(0), end: t(12))]
        let added = project.addPieces(pieces, intoTimeline: project.rootTimelineID, kind: .video)
        #expect(added == nil)
        #expect(project.timelines[0].layers.isEmpty)
    }

    @Test func anExistingLayerTakesEveryPieceOrNone() throws {
        var project = EditingProject.empty
        let v = video("V"), s = audio("S")
        project.clips = [v, s]
        let first = project.addPieces([MediaPiece(assetID: v.id, start: t(0), end: t(24))], intoTimeline: project.rootTimelineID)
        let layerID = try #require(first).layerID

        let mixed = [MediaPiece(assetID: v.id, start: t(0), end: t(24)), MediaPiece(assetID: s.id, start: t(0), end: t(12))]
        let refused = project.addPieces(mixed, intoLayer: layerID, in: project.rootTimelineID, at: t(100))
        #expect(refused == nil)
        #expect(project.timelines[0].layers[0].clips.count == 1)

        let added = project.addPieces([MediaPiece(assetID: v.id, start: t(48), end: t(60))], intoLayer: layerID, in: project.rootTimelineID, at: t(100))
        #expect(added?.count == 1)
        #expect(project.timelines[0].layers[0].clips.map(\.startOffset) == [t(0), t(100)])
    }

    @Test func theLandingPreviewShowsWhereADropWouldGoWithoutChangingAnything() throws {
        var project = EditingProject.empty
        let v = video("V"), s = audio("S")
        project.clips = [v, s]
        let first = project.addPieces([MediaPiece(assetID: v.id, start: t(0), end: t(48))], intoTimeline: project.rootTimelineID)
        let layerID = try #require(first).layerID
        let before = project

        let pieces = [MediaPiece(assetID: v.id, start: t(100), end: t(124))]
        // Dropped over the clip already there, it moves to the gap after it.
        let preview = try #require(project.landing(of: pieces, onLayer: layerID, in: project.rootTimelineID, at: t(24)))
        #expect(project == before)
        #expect(preview.map(\.startOffset) == [t(48)])

        var dropped = project
        let added = dropped.addPieces(pieces, intoLayer: layerID, in: project.rootTimelineID, at: t(24))
        let placed = dropped.timelines[0].layers[0].clips.filter { added?.contains($0.id) == true }
        #expect(placed.map(\.startOffset) == preview.map(\.startOffset))

        // Sound can't go on a video layer, so there is no preview there.
        let sound = [MediaPiece(assetID: s.id, start: t(0), end: t(24))]
        #expect(project.landing(of: sound, onLayer: layerID, in: project.rootTimelineID, at: t(100)) == nil)
    }

    @Test func mediaDroppedOnALayerPushesTheClipsAfterItAsAMoveWould() throws {
        var project = EditingProject.empty
        let v = video("V")
        project.clips = [v]
        let timelineID = project.rootTimelineID
        let first = project.addPieces([MediaPiece(assetID: v.id, start: t(0), end: t(48))], intoTimeline: timelineID)
        let layerID = try #require(first).layerID
        _ = project.addPieces([MediaPiece(assetID: v.id, start: t(0), end: t(24))], intoLayer: layerID, in: timelineID, at: t(60))
        // Clips at 0-48 and 60-84. Two pieces, 36 frames together, dropped
        // nearer the end of the first clip: they go at 48 and push the
        // second clip right just enough, from 60 to 84.
        let pieces = [MediaPiece(assetID: v.id, start: t(100), end: t(124)), MediaPiece(assetID: v.id, start: t(200), end: t(212))]
        let pushed = project.pushedByPieces(pieces, onLayer: layerID, in: timelineID, at: t(30))
        #expect(pushed.values.map(\.to) == [t(84)])

        let added = project.addPieces(pieces, intoLayer: layerID, in: timelineID, at: t(30))
        #expect(added?.count == 2)
        let starts = project.timelines[0].layers[0].clips.map(\.startOffset)
        #expect(starts == [t(0), t(48), t(72), t(84)])
    }

    @Test func aMoveAndADropOfTheSameLengthLandAlike() throws {
        var project = EditingProject.empty
        let v = video("V")
        project.clips = [v]
        let timelineID = project.rootTimelineID
        let first = project.addPieces([MediaPiece(assetID: v.id, start: t(0), end: t(48))], intoTimeline: timelineID)
        let layerID = try #require(first).layerID
        let timeline = try #require(project.timeline(id: timelineID))
        let others = timeline.layers[0].clips
        let move = project.insertion(lasting: t(24), frameLocked: true, among: others, in: timeline, at: t(10))
        // Inside the clip, nearer its start: before it, pushing it 24 frames.
        #expect(move.start == t(0))
        #expect(move.push == t(24))
        let pushed = project.pushedByPieces([MediaPiece(assetID: v.id, start: t(0), end: t(24))], onLayer: layerID, in: timelineID, at: t(10))
        #expect(pushed.values.map(\.to) == [t(24)])
    }

    @Test func mutingSoundMutesOnlyVideoThatCarriesSound() throws {
        var project = EditingProject.empty
        var loud = video("Loud")
        loud.hasAudio = true
        let quiet = video("Quiet"), s = audio("S")
        project.clips = [loud, quiet, s]
        let pieces = [loud, quiet, s].map { MediaPiece(assetID: $0.id, start: t(0), end: t(24)) }
        let added = project.addPieces(pieces, intoTimeline: project.rootTimelineID, mutingSound: true)
        let ids = try #require(added).clipIDs
        let clips = project.timelines[0].layers.flatMap(\.clips)
        func muted(_ id: UUID) -> Bool? { clips.first { $0.id == id }?.soundMuted }
        #expect(muted(ids[0]) == true)
        #expect(muted(ids[1]) == false)
        // Sound on its own is what is wanted from the clip.
        #expect(muted(ids[2]) == false)
    }

    @Test func mutingSoundMutesVideoDroppedOnALayer() throws {
        var project = EditingProject.empty
        var loud = video("Loud")
        loud.hasAudio = true
        project.clips = [loud]
        let piece = MediaPiece(assetID: loud.id, start: t(0), end: t(24))
        let first = project.addPieces([piece], intoTimeline: project.rootTimelineID)
        let layerID = try #require(first).layerID
        let added = project.addPieces([piece], intoLayer: layerID, in: project.rootTimelineID, at: t(48), mutingSound: true)
        let id = try #require(added?.first)
        let clips = project.timelines[0].layers[0].clips
        #expect(clips.map(\.soundMuted) == clips.map { $0.id == id })
    }
}
