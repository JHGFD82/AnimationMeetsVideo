import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Working on several clips together: copy, paste, duplicate, delete and
/// putting them in a timeline of their own.
@Suite struct ClipGroupTests {
    private func t(_ frame: Int64) -> CMTime { CMTime(value: frame, timescale: 24) }

    private func video(_ name: String) -> MediaClip {
        MediaClip(name: name, kind: .video, url: nil, duration: t(240), frameRate: 24, colorSpace: .rec709, codecName: "Test")
    }

    /// Layer `top`, made second, with clips at frames 0 and 24; layer
    /// `bottom`, made first, with one clip at frame 12 (24 frames each).
    private struct Fixture {
        var project: EditingProject
        var topLayer: UUID
        var bottomLayer: UUID
        var topClips: [UUID]
        var bottomClip: UUID
        var timeline: UUID { project.rootTimelineID }
    }

    private func fixture() throws -> Fixture {
        var project = EditingProject.empty
        let a = video("A"), b = video("B")
        project.clips = [a, b]
        let bottomAdded = project.addPieces([MediaPiece(assetID: b.id, start: t(0), end: t(24))], intoTimeline: project.rootTimelineID)
        let bottom = try #require(bottomAdded)
        let topAdded = project.addPieces(
            [MediaPiece(assetID: a.id, start: t(0), end: t(24)), MediaPiece(assetID: a.id, start: t(24), end: t(48))],
            intoTimeline: project.rootTimelineID
        )
        let top = try #require(topAdded)
        project.moveClip(bottom.clipIDs[0], in: project.rootTimelineID, layer: bottom.layerID, to: t(12))
        return Fixture(project: project, topLayer: top.layerID, bottomLayer: bottom.layerID, topClips: top.clipIDs, bottomClip: bottom.clipIDs[0])
    }

    private func starts(_ project: EditingProject, _ layerID: UUID) -> [CMTime] {
        project.timelines[0].layer(id: layerID)?.clips.map(\.startOffset) ?? []
    }

    @Test func aGroupKeepsItsClipsPlacesInTimeAndAcrossLayers() throws {
        let f = try fixture()
        let ids = Set(f.topClips + [f.bottomClip])
        let group = try #require(f.project.clipGroup(ids, in: f.timeline))
        #expect(group.start == t(0))
        #expect(group.end == t(48))
        #expect(group.bundles.map(\.clip.startOffset) == [t(0), t(12), t(24)])
    }

    @Test func pastingAGroupLaysItOutFromTheStartOntoOneLayerPerSourceLayer() throws {
        var f = try fixture()
        let ids = Set(f.topClips + [f.bottomClip])
        let group = try #require(f.project.clipGroup(ids, in: f.timeline))
        let other = f.project.addTimeline(name: "Other", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        let placed = f.project.paste(group, in: other, at: t(100))
        #expect(placed.count == 3)
        let layers = try #require(f.project.timeline(id: other)).layers
        #expect(layers.count == 2)
        let starts = layers.map { $0.clips.map(\.startOffset) }.sorted { $0.count > $1.count }
        #expect(starts == [[t(100), t(124)], [t(112)]])
    }

    @Test func duplicatingAGroupPutsCopiesRightAfterIt() throws {
        var f = try fixture()
        let ids = Set(f.topClips + [f.bottomClip])
        let copies = f.project.duplicateClips(ids, in: f.timeline)
        #expect(copies.count == 3)
        #expect(starts(f.project, f.topLayer) == [t(0), t(24), t(48), t(72)])
        #expect(starts(f.project, f.bottomLayer) == [t(12), t(60)])
    }

    @Test func deletingAGroupRemovesTheClipsAndKeepsTheLayers() throws {
        var f = try fixture()
        f.project.deleteClips([f.topClips[0], f.bottomClip], in: f.timeline)
        #expect(f.project.timelines[0].layer(id: f.topLayer)?.clips.map(\.id) == [f.topClips[1]])
        #expect(f.project.timelines[0].layer(id: f.bottomLayer)?.clips.isEmpty == true)
    }

    @Test func nestingMovesTheClipsIntoATimelineOfTheirOwnAndPutsItInTheirPlace() throws {
        var f = try fixture()
        let ids = Set([f.topClips[1], f.bottomClip])
        let nestedResult = f.project.nestClips(ids, in: f.timeline, named: "Group")
        let nested = try #require(nestedResult)

        // The new timeline has both clips, from zero, on their own layers.
        let inner = try #require(f.project.timeline(id: nested.timelineID))
        #expect(inner.name == "Group")
        #expect(inner.layers.count == 2)
        #expect(Set(inner.layers.flatMap(\.clips).map(\.id)) == ids)
        #expect(inner.layers.flatMap(\.clips).map(\.startOffset).sorted(by: { $0 < $1 }) == [t(0), t(12)])

        // Out of the original layers, one clip standing in for them from
        // where the earliest started (frame 12).
        #expect(f.project.timelines[0].layer(id: f.topLayer)?.clips.map(\.id) == [f.topClips[0]])
        #expect(f.project.timelines[0].layer(id: f.bottomLayer)?.clips.isEmpty == true)
        let outer = try #require(f.project.timelines[0].layer(id: nested.layerID))
        #expect(outer.clips.count == 1)
        #expect(outer.clips[0].source == .timeline(nested.timelineID))
        #expect(outer.clips[0].startOffset == t(12))
        #expect(outer.clips[0].placedDuration == inner.duration)
        #expect(f.project.timelines[0].layers.first?.id == nested.layerID)
    }
}
