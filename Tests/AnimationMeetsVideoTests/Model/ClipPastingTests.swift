import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ClipPastingTests {
    private func t(_ frame: Int64) -> CMTime { CMTime(value: frame, timescale: 24) }

    private func video(_ name: String) -> MediaClip {
        MediaClip(name: name, kind: .video, url: nil, duration: t(240), frameRate: 24, colorSpace: .rec709, codecName: "Test")
    }

    /// A project with one video clip of 24 frames at 0, on one layer.
    private func fixture() throws -> (project: EditingProject, layerID: UUID, clipID: UUID) {
        var project = EditingProject.empty
        let a = video("A")
        project.clips = [a]
        let addedResult = project.addPieces([MediaPiece(assetID: a.id, start: t(0), end: t(24))], intoTimeline: project.rootTimelineID)
        let added = try #require(addedResult)
        return (project, added.layerID, added.clipIDs[0])
    }

    private func clips(_ project: EditingProject, _ layerID: UUID) -> [TimelineClip] {
        project.timelines[0].layer(id: layerID)?.clips ?? []
    }

    @Test func duplicatingPutsACopyRightAfterTheClip() throws {
        var (project, layerID, clipID) = try fixture()
        let copyIDResult = project.duplicateClip(clipID, in: project.rootTimelineID)
        let copyID = try #require(copyIDResult)
        let layer = clips(project, layerID)
        #expect(layer.map(\.id) == [clipID, copyID])
        #expect(layer.map(\.startOffset) == [t(0), t(24)])
        #expect(layer[1].trimStart == layer[0].trimStart && layer[1].trimEnd == layer[0].trimEnd)
    }

    @Test func pastingInsideAClipGoesToItsNearerEdgeAndPushesTheRest() throws {
        var (project, layerID, clipID) = try fixture()
        let bundle = try #require(project.clipBundle(clipID, in: project.rootTimelineID))
        let pastedResult = project.paste(bundle, in: project.rootTimelineID, onto: layerID, at: t(4))
        let pasted = try #require(pastedResult)
        let layer = clips(project, layerID)
        #expect(pasted.layerID == layerID)
        #expect(layer.map(\.id) == [pasted.clipID, clipID])
        #expect(layer.map(\.startOffset) == [t(0), t(24)])
    }

    @Test func pastingIntoAnotherTimelineMakesALayerOfItsKind() throws {
        var (project, _, clipID) = try fixture()
        let bundle = try #require(project.clipBundle(clipID, in: project.rootTimelineID))
        let other = project.addTimeline(name: "Other", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        let pastedResult = project.paste(bundle, in: other, onto: nil, at: t(48))
        let pasted = try #require(pastedResult)
        let layer = try #require(project.timeline(id: other)?.layer(id: pasted.layerID))
        #expect(layer.kind == .video)
        #expect(layer.clips.map(\.startOffset) == [t(48)])
    }

    @Test func aTimelineCantBePastedIntoItself() throws {
        var project = EditingProject.empty
        let inner = project.addTimeline(name: "Inner", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        let a = video("A")
        project.clips = [a]
        project.addPieces([MediaPiece(assetID: a.id, start: t(0), end: t(24))], intoTimeline: inner)
        let nestedResult = project.embedTimeline(inner, intoTimeline: project.rootTimelineID)
        let nested = try #require(nestedResult)
        let bundle = try #require(project.clipBundle(nested.clipID, in: project.rootTimelineID))
        #expect(project.paste(bundle, in: inner, onto: nil, at: .zero) == nil)
        #expect(project.paste(bundle, in: project.rootTimelineID, onto: nil, at: .zero) != nil)
    }

    @Test func pastingOntoANewLayerPutsItAtTheTop() throws {
        var (project, layerID, clipID) = try fixture()
        let bundle = try #require(project.clipBundle(clipID, in: project.rootTimelineID))
        let pastedResult = project.paste(bundle, in: project.rootTimelineID, newLayer: .video, at: t(12))
        let pasted = try #require(pastedResult)
        #expect(project.timelines[0].layers.map(\.id) == [pasted.layerID, layerID])
        #expect(clips(project, pasted.layerID).map(\.startOffset) == [t(12)])
    }

    @Test func duplicatingALayerCopiesItsClipsBelowItOrWhereAsked() throws {
        var (project, layerID, clipID) = try fixture()
        project.timelines[0].layers[0].customName = "Hero"
        let copyResult = project.duplicateLayer(layerID, in: project.rootTimelineID)
        let copyID = try #require(copyResult)
        #expect(project.timelines[0].layers.map(\.id) == [layerID, copyID])
        let copy = try #require(project.timelines[0].layer(id: copyID))
        #expect(copy.customName == "Hero copy")
        #expect(copy.clips.count == 1 && copy.clips[0].id != clipID)
        // Asked for the top: above the original.
        let topResult = project.duplicateLayer(layerID, in: project.rootTimelineID, toPositionInKind: 0)
        let top = try #require(topResult)
        #expect(project.timelines[0].layers.first?.id == top)
    }

    @Test func aCopysEffectsPointAtEachOther() throws {
        var (project, _, clipID) = try fixture()
        let transform = Effect(kind: .transform)
        var wiggler = Effect(kind: .wiggler)
        wiggler.keyframing?.target = .control(effectID: transform.id, controlID: transform.controls[0].id)
        wiggler.against = transform.id
        project.editClip(clipID, in: project.rootTimelineID) { $0.effects = [wiggler, transform] }

        let original = try #require(project.clipAndLayer(clipID, in: project.rootTimelineID)?.clip)
        let copy = original.duplicated()
        #expect(copy.id != original.id)
        #expect(Set(copy.effects.map(\.id)).isDisjoint(with: original.effects.map(\.id)))
        let newTransform = copy.effects[1]
        #expect(copy.effects[0].against == newTransform.id)
        #expect(copy.effects[0].keyframing?.target == .control(effectID: newTransform.id, controlID: newTransform.controls[0].id))
    }
}
