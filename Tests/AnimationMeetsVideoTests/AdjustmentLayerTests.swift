import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct AdjustmentLayerModelTests {
    private func project(layers: Int) -> (project: EditingProject, layers: [UUID]) {
        var project = EditingProject.empty
        let media = MediaClip(name: "m", kind: .video, url: nil, duration: CMTime(value: 10, timescale: 1), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        var ids: [UUID] = []
        for _ in 0..<layers { ids.append(project.importClip(media, intoTimeline: project.rootTimelineID)!.layerID) }
        // importClip puts each on top, so the last is the top layer.
        return (project, ids.reversed())
    }

    @Test func anAdjustmentLayerIsAVideoLayerHoldingAnAdjustmentClipTheLengthOfTheTimeline() throws {
        var (p, _) = project(layers: 2)
        let t = p.rootTimelineID
        let added = p.addAdjustmentLayer(to: t)
        let created = try #require(added)
        let timeline = try #require(p.timeline(id: t))
        #expect(timeline.layers.first?.id == created.layerID)
        let layer = timeline.layers[0]
        #expect(layer.isAdjustment && layer.kind == .video && layer.reach == nil)
        let clip = layer.clips[0]
        #expect(clip.source == .adjustment && clip.startOffset == .zero)
        #expect(clip.trimmedDuration == timeline.frameAligned(CMTime(value: 10, timescale: 1), .down))
        #expect(p.hasEffectStack(clip) && p.playsVideo(clip) && !p.playsAudio(clip))
        #expect(p.displayName(of: layer, in: timeline) == "Adjustment 1")
    }

    @Test func anEmptyTimelineGetsAnAdjustmentFiveSecondsLong() throws {
        var p = EditingProject.empty
        let addedAdded = p.addAdjustmentLayer(to: p.rootTimelineID)
        let added = try #require(addedAdded)
        let clip = try #require(p.clipAndLayer(added.clipID, in: p.rootTimelineID)?.clip)
        #expect(clip.trimmedDuration == CMTime(value: 5, timescale: 1))
    }

    @Test func layersTakeOnlyTheClipsTheyAreFor() throws {
        var (p, layers) = project(layers: 1)
        let t = p.rootTimelineID
        let adjustmentAdded = p.addAdjustmentLayer(to: t)
        let adjustment = try #require(adjustmentAdded)
        let timeline = try #require(p.timeline(id: t))
        let video = try #require(timeline.layer(id: layers[0]))
        let adjustmentLayer = try #require(timeline.layer(id: adjustment.layerID))
        let picture = video.clips[0]
        let adjust = adjustmentLayer.clips[0]
        #expect(p.layer(video, accepts: picture) && !p.layer(video, accepts: adjust))
        #expect(p.layer(adjustmentLayer, accepts: adjust) && !p.layer(adjustmentLayer, accepts: picture))
        // So a clip can't be moved onto the wrong layer.
        #expect(p.resolvedMove(ofMoving: picture.id, in: t, layer: video.id, onto: adjustmentLayer.id, to: .zero) == nil)
        #expect(p.resolvedMove(ofMoving: adjust.id, in: t, layer: adjustmentLayer.id, onto: video.id, to: .zero) == nil)
    }

    @Test func reachIsTheLayersBelowDownToTheOneChosenAndNothingWhenItIsAbove() throws {
        var (p, layers) = project(layers: 4)         // layers[0] on top ... layers[3] at the bottom
        let t = p.rootTimelineID
        let addedLayer = p.addAdjustmentLayer(to: t, at: 1)   // between layers[0] and layers[1]
        let added = try #require(addedLayer)
        func reached() -> [UUID] {
            let timeline = p.timeline(id: t)!
            return p.reachedLayers(of: timeline.layer(id: added.layerID)!, in: timeline).map(\.id)
        }
        #expect(reached() == [layers[1], layers[2], layers[3]])
        p.setReach(of: added.layerID, in: t, toLayer: layers[2])
        #expect(reached() == [layers[1], layers[2]])
        // Adding a layer in between doesn't change where it stops.
        let media = MediaClip(name: "m", kind: .video, url: nil, duration: CMTime(value: 1, timescale: 1), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let extra = p.importClip(media, intoTimeline: t)!.layerID
        p.moveLayer(extra, in: t, toIndex: 3)
        #expect(reached().last == layers[2] && reached().count == 3)
        // Moved above the adjustment, the chosen layer is reached by nothing.
        p.moveLayer(layers[2], in: t, toIndex: 0)
        #expect(reached().isEmpty)
        let timeline = p.timeline(id: t)!
        #expect(p.reachesNothing(timeline.layer(id: added.layerID)!, in: timeline))
        // Deleted, the reach goes back to every layer below.
        p.deleteLayer(layers[2], in: t)
        #expect(p.timeline(id: t)!.layer(id: added.layerID)!.reach == nil)
        #expect(!reached().isEmpty)
    }

    @Test func reachOnlyTakesALayerOfTheTimeline() throws {
        var (p, _) = project(layers: 1)
        let addedAdded = p.addAdjustmentLayer(to: p.rootTimelineID)
        let added = try #require(addedAdded)
        p.setReach(of: added.layerID, in: p.rootTimelineID, toLayer: UUID())
        #expect(p.timeline(id: p.rootTimelineID)!.layer(id: added.layerID)!.reach == nil)
    }

    @Test func movingAnAdjustmentClipToANewLayerMakesAnAdjustmentLayer() throws {
        var (p, _) = project(layers: 1)
        let t = p.rootTimelineID
        let addedAdded = p.addAdjustmentLayer(to: t)
        let added = try #require(addedAdded)
        let newLayerAdded = p.moveClipToNewLayer(added.clipID, in: t, layer: added.layerID, kind: .video)
        let newLayer = try #require(newLayerAdded)
        #expect(p.timeline(id: t)!.layer(id: newLayer)!.isAdjustment)
    }
}

@Suite struct AdjustmentDrawingTests {
    private func gain(_ amount: Double) -> Effect {
        var effect = Effect(kind: .color, controls: [EffectControl(kind: .gain)])
        effect.controls[0].number = AnimatedValue(ComponentValue(values: [amount, 1, 1, 1]))
        return effect
    }

    private func desaturate() -> Effect {
        var effect = Effect(kind: .color, controls: [EffectControl(kind: .saturation)])
        effect.controls[0].number = AnimatedValue(ComponentValue(values: [0]))
        return effect
    }

    @Test func anAdjustmentOverEveryLayerGradesTheirComposite() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0.55, 0.4, 0.3, 1))
        let grade = gain(0.5)
        let adjusted = try harness.draw([CompositorHarness.adjustment(effects: [grade]), CompositorHarness.clip(track: 1)])
        // The same as the effect on the clip itself.
        let direct = try harness.draw([CompositorHarness.clip(track: 1, effects: [grade])])
        let plain = try harness.draw([CompositorHarness.clip(track: 1)])
        #expect(close(harness.pixel(adjusted, x: 8, y: 4), harness.pixel(direct, x: 8, y: 4)))
        #expect(!close(harness.pixel(adjusted, x: 8, y: 4), harness.pixel(plain, x: 8, y: 4)))
    }

    @Test func aReachOfSomeLayersAdjustsOnlyWhereTheyAre() throws {
        var harness = CompositorHarness()
        // The reached layer covers the left half; below it, one blue layer.
        try harness.addPicture(track: 1) { x, _ in x < 0.5 ? SIMD4(0.9, 0.1, 0.1, 1) : SIMD4(0, 0, 0, 0) }
        try harness.addSolid(track: 2, SIMD4(0.1, 0.2, 0.9, 1))
        let reached = UUID(), below = UUID()
        let frame = try harness.draw([
            CompositorHarness.adjustment(effects: [desaturate()], reaching: [reached]),
            CompositorHarness.clip(track: 1, layer: reached),
            CompositorHarness.clip(track: 2, layer: below),
        ])
        let left = harness.pixel(frame, x: 3, y: 4), right = harness.pixel(frame, x: 12, y: 4)
        // Where the layer is, the red it covers over the blue is gray.
        #expect(abs(left.x - left.y) < 0.02 && abs(left.y - left.z) < 0.02)
        // Where it isn't, what is below is left alone.
        #expect(close(right, SIMD4(0.1, 0.2, 0.9, 1)))
    }

    @Test func layersOutsideTheReachStillShowAsTheyWere() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0.8, 0.8, 0.2, 1))
        try harness.addSolid(track: 2, SIMD4(0.1, 0.2, 0.9, 1))
        let top = UUID(), bottom = UUID()
        // The adjustment reaches the top layer only, and the layer below
        // shows through nothing: the top one covers the frame.
        let frame = try harness.draw([
            CompositorHarness.adjustment(effects: [gain(0.5)], reaching: [top]),
            CompositorHarness.clip(track: 1, layer: top),
            CompositorHarness.clip(track: 2, layer: bottom),
        ])
        let direct = try harness.draw([CompositorHarness.clip(track: 1, effects: [gain(0.5)]), CompositorHarness.clip(track: 2)])
        #expect(close(harness.pixel(frame, x: 8, y: 4), harness.pixel(direct, x: 8, y: 4)))
    }

    @Test func anAdjustmentThatReachesNothingChangesNothing() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0.55, 0.4, 0.3, 1))
        let flat = try harness.draw([CompositorHarness.adjustment(effects: [gain(0.5)], reaching: []), CompositorHarness.clip(track: 1)])
        let plain = try harness.draw([CompositorHarness.clip(track: 1)])
        #expect(close(harness.pixel(flat, x: 8, y: 4), harness.pixel(plain, x: 8, y: 4)))
    }

    @Test func aMoveOnAnAdjustmentMovesTheWholePicture() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0.9, 0.2, 0.2, 1))
        try harness.addSolid(track: 2, SIMD4(0.2, 0.2, 0.9, 1))
        var move = Effect(kind: .transform, controls: [EffectControl(kind: .position)])
        move.controls[0].number = AnimatedValue(ComponentValue(values: [8, 0]))
        // Both layers move together, as one picture, half a frame right.
        let frame = try harness.draw([
            CompositorHarness.adjustment(effects: [move]),
            CompositorHarness.clip(track: 1, effects: [], layer: UUID()),
            CompositorHarness.clip(track: 2),
        ])
        #expect(harness.pixel(frame, x: 12, y: 4).x > 0.8)
        #expect(harness.pixel(frame, x: 3, y: 4).w < 0.05)
    }

    @Test func anAdjustmentsBlendingStepBlendsWithThePictureItReceived() throws {
        var harness = CompositorHarness()
        // A gradient left to right, scaled down by the adjustment and
        // blended with the unscaled one.
        try harness.addPicture(track: 1) { x, _ in SIMD4(Float(x), Float(x), Float(x), 1) }
        var shrink = Effect(kind: .transform, controls: [EffectControl(kind: .scale)])
        shrink.controls[0].number = AnimatedValue(ComponentValue(values: [50, 50]))
        var difference = Effect(kind: .blending)
        difference.controls[0].blendMode = .difference
        let frame = try harness.draw([
            CompositorHarness.adjustment(effects: [shrink, difference]),
            CompositorHarness.clip(track: 1),
        ])
        // Right of center, the shrunk picture shows what was further right,
        // and the difference is how far apart the two are (0.8125 against
        // 0.65625 at the tenth column), not zero as against itself.
        let pixel = harness.pixel(frame, x: 10, y: 4)
        #expect(pixel.w > 0.95 && abs(pixel.x - 0.156) < 0.03)
    }

    @Test func aStretchOfAnAdjustmentNeedsRenderingAndIsNamedByItsClip() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.addClip(luma: 200)
        let addedAdded = fixture.project.addAdjustmentLayer(to: fixture.timelineID, from: CMTime(value: 12, timescale: 24), duration: CMTime(value: 12, timescale: 24))
        let added = try #require(addedAdded)
        var exposure = Effect(kind: .color, controls: [EffectControl(kind: .exposure)])
        exposure.controls[0].number = AnimatedValue(ComponentValue(values: [-2]))
        fixture.project.editClip(added.clipID, in: fixture.timelineID) { $0.effects = [exposure] }

        let composed = try await fixture.build()
        // The timeline is split where the adjustment starts, and only that
        // stretch is rendered.
        let rendered = composed.segments.filter(\.needsRender)
        #expect(!rendered.isEmpty)
        #expect(rendered.allSatisfy { $0.range.start >= CMTime(value: 12, timescale: 24) })
        #expect(rendered.allSatisfy { $0.clipIDs.contains(added.clipID) })
        let before = try await grayLevel(of: composed, at: CMTime(value: 6, timescale: 24))
        let during = try await grayLevel(of: composed, at: CMTime(value: 18, timescale: 24))
        #expect(during < before - 20)
    }
}
