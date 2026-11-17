import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Coloring clips and sections, and Clear Layer (docs/bar-colors.md,
/// "Model").
@Suite struct BarColorEditTests {
    private func t(_ frame: Int64) -> CMTime { CMTime(value: frame, timescale: 24) }
    private let red = BarColor(0xDF6862), teal = BarColor(0x05A7A7)

    /// Two layers: `top` with two clips, `bottom` with one, 24 frames each.
    private func fixture() throws -> (project: EditingProject, top: UUID, topClips: [UUID], bottom: UUID, bottomClip: UUID) {
        var project = EditingProject.empty
        let media = MediaClip(name: "A", kind: .video, url: nil, duration: t(240), frameRate: 24, colorSpace: .rec709, codecName: "Test")
        project.clips = [media]
        let bottomAdded = project.addPieces([MediaPiece(assetID: media.id, start: t(0), end: t(24))], intoTimeline: project.rootTimelineID)
        let bottom = try #require(bottomAdded)
        let topAdded = project.addPieces(
            [MediaPiece(assetID: media.id, start: t(0), end: t(24)), MediaPiece(assetID: media.id, start: t(24), end: t(48))],
            intoTimeline: project.rootTimelineID
        )
        let top = try #require(topAdded)
        return (project, top.layerID, top.clipIDs, bottom.layerID, bottom.clipIDs[0])
    }

    private func clip(_ id: UUID, in project: EditingProject) -> TimelineClip? {
        project.clipAndLayer(id, in: project.rootTimelineID)?.clip
    }

    @Test func clipsTakeAColorAndGiveItBack() throws {
        var (project, _, topClips, _, bottomClip) = try fixture()
        let t0 = project.rootTimelineID
        project.setColor(red, ofClips: Set(topClips), in: t0)
        #expect(topClips.allSatisfy { clip($0, in: project)?.color == red })
        #expect(clip(bottomClip, in: project)?.color == nil)
        project.setColor(nil, ofClips: [topClips[0]], in: t0)
        #expect(clip(topClips[0], in: project)?.color == nil)
        #expect(clip(topClips[1], in: project)?.color == red)
    }

    @Test func copiesOfAClipKeepItsColor() throws {
        var (project, top, topClips, _, _) = try fixture()
        let t0 = project.rootTimelineID
        project.setColor(teal, ofClips: [topClips[0]], in: t0)

        project.split(topClips[0], in: t0, layer: top, atTimelineTime: t(12))
        let halves = try #require(project.timelines[0].layer(id: top)?.clips.filter { $0.startOffset < t(24) })
        #expect(halves.count == 2 && halves.allSatisfy { $0.color == teal })

        let bundle = try #require(project.clipBundle(topClips[1], in: t0))
        var colored = bundle
        colored.clip.color = teal
        let placed = project.paste(colored, in: t0, onto: nil, at: t(100))
        let pasted = try #require(placed)
        #expect(clip(pasted.clipID, in: project)?.color == teal)
    }

    @Test func clearLayerDeletesItsClipsAndKeepsTheLayer() throws {
        var (project, top, _, bottom, bottomClip) = try fixture()
        let t0 = project.rootTimelineID
        project.renameLayer(top, in: t0, to: "Shots")
        let before = try #require(project.timelines[0].layer(id: top))

        project.clearLayer(top, in: t0)
        let after = try #require(project.timelines[0].layer(id: top))
        #expect(after.clips.isEmpty)
        #expect(after.customName == "Shots" && after.kind == before.kind && after.volume == before.volume)
        #expect(project.timelines[0].layers.map(\.id).contains(top))
        // Other layers are untouched.
        #expect(project.timelines[0].layer(id: bottom)?.clips.map(\.id) == [bottomClip])

        // An empty layer: nothing changes.
        let cleared = project
        project.clearLayer(top, in: t0)
        #expect(project == cleared)
    }

    @Test func sectionsTakeAColorAndTheirCopiesKeepIt() throws {
        var project = EditingProject.empty
        let t0 = project.rootTimelineID
        let added = project.addSection(named: "Chorus", in: t0, from: .zero, to: t(48))
        let id = try #require(added)
        project.setColor(red, ofSection: id, in: t0)
        #expect(project.timelines[0].sections.first?.color == red)
        let copy = try #require(project.resolvedSectionCopy(id, in: t0, to: t(96)))
        #expect(copy.color == red)
        project.setColor(nil, ofSection: id, in: t0)
        #expect(project.timelines[0].sections.first?.color == nil)
    }
}
