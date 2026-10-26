import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Text and the shapes as generators: clips of their own, never effects
/// in a footage clip's stack (see docs/graphic-layers.md).
@Suite struct GeneratorTests {
    private func second(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    /// A project with ten seconds of footage on one video layer.
    private func footage() -> (project: EditingProject, layerID: UUID, clipID: UUID) {
        var project = EditingProject.empty
        let media = MediaClip(
            name: "m", kind: .video, url: nil, duration: second(10), frameRate: 24,
            colorSpace: .rec709, codecName: "H.264", hasAudio: true
        )
        let placed = project.importClip(media, intoTimeline: project.rootTimelineID)!
        return (project, placed.layerID, placed.clipID)
    }

    @Test @MainActor func theGeneratorsAreTextThenTheShapesAndNoneIsInTheEffectsLibrary() {
        #expect(EffectKind.generators == [.text, .rectangle, .ellipse, .polygon, .star])
        let library = EffectsListPanel.kinds
        #expect(library.allSatisfy { !$0.drawsShape })
        // What works on text and shapes in their clip's stack stays.
        #expect(library.contains(.stroke))
        #expect(library.contains(.textAnimator))
    }

    @Test func aShapeOrTextGoesOnlyIntoAGraphicClip() throws {
        var (project, _, clipID) = footage()
        let t = project.rootTimelineID
        let added1 = project.addEffect(.rectangle, toClip: clipID, in: t)
        #expect(added1 == nil)
        let added2 = project.addEffect(.text, toClip: clipID, in: t)
        #expect(added2 == nil)
        let added3 = project.addEffect(.color, toClip: clipID, in: t)
        #expect(added3 != nil)

        let shapeMade = project.addShapeLayer(.rectangle, to: t)

        let shape = try #require(shapeMade)
        // Text joins a shape clip below the shape, to follow its path, and
        // a Stroke strokes them.
        let added4 = project.addEffect(.text, toClip: shape.clipID, in: t)
        #expect(added4 != nil)
        let added5 = project.addEffect(.stroke, toClip: shape.clipID, in: t)
        #expect(added5 != nil)
        let clip = try #require(project.clipAndLayer(shape.clipID, in: t)?.clip)
        #expect(clip.effects.map(\.kind) == [.rectangle, .text, .stroke])
    }

    @Test func pastingOntoFootageLeavesTheShapesBehind() throws {
        var (project, _, clipID) = footage()
        let t = project.rootTimelineID
        let shapeMade = project.addShapeLayer(.star, to: t)
        let shape = try #require(shapeMade)
        project.addEffect(.color, toClip: shape.clipID, in: t)
        let bundle = try #require(project.bundle(ofEffects: nil, fromClip: shape.clipID, in: t))

        let pasted = project.paste(bundle, ontoClip: clipID, in: t)
        #expect(pasted.count == 1)
        #expect(project.clipAndLayer(clipID, in: t)?.clip.effects.map(\.kind) == [.color])

        // Onto another shape clip, all of it comes along.
        let otherMade = project.addShapeLayer(.ellipse, to: t)
        let other = try #require(otherMade)
        project.paste(bundle, ontoClip: other.clipID, in: t)
        #expect(project.clipAndLayer(other.clipID, in: t)?.clip.effects.map(\.kind) == [.ellipse, .star, .color])
    }

    @Test func aGeneratorStartsALayerAtTheTop() throws {
        var (project, footageLayer, _) = footage()
        let t = project.rootTimelineID
        let created = project.addShapeLayer(.text, to: t, from: second(2))
        let made = try #require(created)
        let layers = try #require(project.timeline(id: t)?.layers)
        #expect(layers.map(\.id) == [made.layerID, footageLayer])
        let clip = try #require(project.clipAndLayer(made.clipID, in: t)?.clip)
        #expect(clip.source == .graphic)
        #expect(clip.startOffset == second(2))
        #expect(clip.effects.map(\.kind) == [.text])
        // Only generators make one.
        let notAGenerator = project.addShapeLayer(.color, to: t)
        #expect(notAGenerator == nil)
    }

    @Test func aGeneratorDroppedOnALayerLandsAsAMovedClipWould() throws {
        var (project, footageLayer, footageClip) = footage()
        let t = project.rootTimelineID

        // Past the footage's end: on the layer, where it was dropped.
        let afterMade = project.addGenerator(.ellipse, to: t, onLayer: footageLayer, at: second(12))
        let after = try #require(afterMade)
        #expect(after.layerID == footageLayer)
        #expect(project.clipAndLayer(after.clipID, in: t)?.clip.startOffset == second(12))

        // Inside the footage, nearer its start: at its start, and the
        // footage moves right to make room.
        let beforeMade = project.addGenerator(.rectangle, to: t, onLayer: footageLayer, at: second(1))
        let before = try #require(beforeMade)
        let placed = try #require(project.clipAndLayer(before.clipID, in: t)?.clip)
        #expect(placed.startOffset == .zero)
        let pushed = try #require(project.clipAndLayer(footageClip, in: t)?.clip)
        #expect(pushed.startOffset >= placed.endOffset)
        let clips = try #require(project.timeline(id: t)?.layers.first(id: footageLayer)?.clips)
        #expect(clips.first?.id == before.clipID)
        #expect(clips.count == 3)
    }

    @Test func aLayerThatCantTakeOneGetsANewLayerAboveIt() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let adjustmentMade = project.addAdjustmentLayer(to: t, from: .zero)
        let adjustment = try #require(adjustmentMade)
        let created = project.addGenerator(.star, to: t, onLayer: adjustment.layerID, at: second(1))
        let made = try #require(created)
        #expect(made.layerID != adjustment.layerID)
        let layers = try #require(project.timeline(id: t)?.layers)
        let madeIndex = try #require(layers.firstIndex(id: made.layerID))
        let adjustmentIndex = try #require(layers.firstIndex(id: adjustment.layerID))
        #expect(madeIndex < adjustmentIndex)
    }

    @Test func aGeneratorDragCarriesOnlyAGenerator() {
        let payload = GeneratorDragPayload(kind: .text)
        #expect(GeneratorDragPayload(url: payload.url)?.kind == .text)
        #expect(GeneratorDragPayload(url: URL(string: "amv-generator:color")!) == nil)
        // An effect drag isn't one, nor is a generator an effect drag.
        #expect(GeneratorDragPayload(url: URL(string: "amv-effect:rectangle")!) == nil)
        #expect(EffectDragPayload(url: payload.url) == nil)
    }
}
