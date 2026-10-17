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
}
