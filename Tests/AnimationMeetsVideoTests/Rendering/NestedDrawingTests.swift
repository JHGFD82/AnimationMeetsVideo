import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Nested timelines are closed groups: drawn on their own, as one picture,
/// unless they pass through.
@Suite struct NestedDrawingTests {
    /// A root with a luma-100 clip at the bottom and, over it, a nested
    /// timeline whose two layers are luma 200 over luma 50, with Opacity
    /// 50% on the nested clip.
    private func fixture(passThrough: Bool) async throws -> (DrawingFixture, UUID) {
        var fixture = try DrawingFixture()
        _ = try await fixture.addClip(luma: 100)

        let nestedID = fixture.project.addTimeline(
            name: "Inner", frameSize: fixture.project.timelines[0].frameSize, frameRate: 24, colorSpace: .rec709
        )
        _ = try await fixture.addClip(luma: 50, to: nestedID)
        _ = try await fixture.addClip(luma: 200, to: nestedID)
        let embedded = fixture.project.embedTimeline(nestedID, intoTimeline: fixture.timelineID)
        let placed = try #require(embedded)
        fixture.setTransform([(.opacity, [50])], ofClip: placed.clipID)
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.passThrough = passThrough }
        return (fixture, placed.clipID)
    }

    @Test func aNestedTimelineIsOnePictureThatFadesAsAWhole() async throws {
        let (closed, _) = try await fixture(passThrough: false)
        defer { closed.cleanUp() }
        let (through, _) = try await fixture(passThrough: true)
        defer { through.cleanUp() }
        let whole = try await grayLevel(of: closed.build(), at: .zero)
        let layerByLayer = try await grayLevel(of: through.build(), at: .zero)
        // As one picture the bright layer hides the dark one before the
        // group fades: half bright over the clip underneath. Layer by layer
        // the dark one fades over it first, so the bright one lands on
        // something darker.
        #expect(whole > layerByLayer + 4)
    }

    @Test func nothingInsideSeesWhatIsUnderIt() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.addClip(luma: 220)
        let nestedID = fixture.project.addTimeline(
            name: "Inner", frameSize: fixture.project.timelines[0].frameSize, frameRate: 24, colorSpace: .rec709
        )
        let inner = try await fixture.addClip(luma: 100, to: nestedID)
        // Inside the group, a quarter-size clip leaves the rest transparent.
        fixture.setTransform([(.scale, [50, 50])], ofClip: inner.clipID, in: nestedID)
        _ = fixture.project.embedTimeline(nestedID, intoTimeline: fixture.timelineID)

        let composed = try await fixture.build()
        let underneath = try await grayLevel(of: composed, at: .zero, x: 0.05, y: 0.05)
        let inside = try await grayLevel(of: composed, at: .zero)
        // The corner shows the clip below through the group's transparency;
        // the middle shows the nested clip.
        #expect(underneath > inside + 20)
    }

    @Test func aNestedTimelineMovesAsOnePicture() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let nestedID = fixture.project.addTimeline(
            name: "Inner", frameSize: fixture.project.timelines[0].frameSize, frameRate: 24, colorSpace: .rec709
        )
        _ = try await fixture.addClip(luma: 200, to: nestedID)
        let embedded = fixture.project.embedTimeline(nestedID, intoTimeline: fixture.timelineID)
        let placed = try #require(embedded)
        let plain = try await grayLevel(of: fixture.build(), at: .zero)
        fixture.setTransform([(.position, [64, 0])], ofClip: placed.clipID)
        let composed = try await fixture.build()
        #expect(try await grayLevel(of: composed, at: .zero, x: 0.25) <= 2)
        #expect(abs(try await grayLevel(of: composed, at: .zero, x: 0.75) - plain) <= 4)
    }

    @Test func passingThroughChangesTheRenderKey() async throws {
        var (closed, closedID) = try await fixture(passThrough: false)
        defer { closed.cleanUp() }
        let before = try await closed.build().segments.first(where: \.needsRender)?.key
        closed.project.editClip(closedID, in: closed.timelineID) { $0.passThrough = true }
        let after = try await closed.build().segments.first(where: \.needsRender)?.key
        #expect(before != nil && after != nil && before != after)
    }

    private func shift(_ x: Double, _ y: Double = 0) -> Effect {
        var effect = Effect(kind: .transform, controls: [EffectControl(kind: .position)])
        effect.controls[0].number = AnimatedValue(ComponentValue(values: [x, y]))
        return effect
    }

    private func turn(_ degrees: Double) -> Effect {
        var effect = Effect(kind: .transform, controls: [EffectControl(kind: .rotation)])
        effect.controls[0].number = AnimatedValue(ComponentValue(values: [degrees]))
        return effect
    }

    /// A nested timeline half the frame's size, holding a 16×8 checkerboard
    /// of single pixels fitted into it, placed back at full size: the net
    /// scale is 1, so what comes out is the checkerboard itself, if the
    /// layer inside is drawn at the size it ends up.
    private func checkerboardInASmallerFrame(pushing: Bool, grading: Bool = true) throws -> (contrast: Float, frame: [SIMD4<Float>]) {
        var harness = CompositorHarness()
        try harness.addPicture(track: 1) { x, y in
            let column = Int(x * 16), row = Int(y * 8)
            let level: Float = (column + row).isMultiple(of: 2) ? 1 : 0
            return SIMD4(level, level, level, 1)
        }
        let nested = CGSize(width: 8, height: 4)
        // A grade inside, which is done on pixels at the size the layer is
        // drawn at (Core Image can't fold it into the move around it).
        var exposure = Effect(kind: .color, controls: [EffectControl(kind: .exposure)])
        exposure.controls[0].number = AnimatedValue(ComponentValue(values: [0.001]))
        let inner = CompositorHarness.clip(
            track: 1, effects: grading ? [exposure] : [], frame: nested, base: CGAffineTransform(scaleX: 0.5, y: 0.5)
        )
        let frame = try harness.draw([
            CompositorHarness.group([inner], nestedFrame: nested, toOuter: CGAffineTransform(scaleX: 2, y: 2), pushesTransforms: pushing)
        ])
        return (abs(harness.pixel(frame, x: 4, y: 3).x - harness.pixel(frame, x: 5, y: 3).x), frame)
    }

    @Test func aNestedTimelineEnlargedKeepsTheDetailOfItsLayers() throws {
        // Drawn at the size it ends up, the checkerboard survives.
        #expect(try checkerboardInASmallerFrame(pushing: true).contrast > 0.9)
        // Drawn at the nested frame's size and then enlarged, it has
        // already been averaged to gray.
        #expect(try checkerboardInASmallerFrame(pushing: false).contrast < 0.2)
        // Without a grade, Core Image folds the moves together itself.
        #expect(try checkerboardInASmallerFrame(pushing: false, grading: false).contrast > 0.9)
    }

    @Test func pushingAMoveGivesTheSamePictureWhereEveryStepIsPerPixel() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0.6, 0.2, 0.4, 1))
        try harness.addSolid(track: 2, SIMD4(0.3, 0.7, 0.5, 1))
        var multiply = Effect(kind: .blending)
        multiply.controls[0].blendMode = .multiply
        func drawn(pushing: Bool) throws -> [SIMD4<Float>] {
            let nested = CompositorHarness.group(
                [CompositorHarness.clip(track: 2, effects: [multiply]), CompositorHarness.clip(track: 1)],
                effects: [shift(4, 2)], pushesTransforms: pushing
            )
            return try harness.draw([nested])
        }
        let pushed = try drawn(pushing: true), whole = try drawn(pushing: false)
        for y in 0..<8 {
            for x in 0..<16 { #expect(close(harness.pixel(pushed, x: x, y: y), harness.pixel(whole, x: x, y: y), tolerance: 0.02), "\(x),\(y)") }
        }
        // And the blended layers did move: the top left is bare.
        #expect(harness.pixel(pushed, x: 1, y: 1).x < 0.02 && harness.pixel(pushed, x: 8, y: 4).x > 0.1)
    }

    @Test func aTurnedNestedTimelineIsLimitedToItsOwnFrame() throws {
        var harness = CompositorHarness(size: CGSize(width: 32, height: 16))
        try harness.addSolid(track: 1, SIMD4(0.9, 0.9, 0.9, 1))
        // The picture is bigger than the nested frame, so only the turned
        // frame shows; its corners cut the rest.
        let inner = CompositorHarness.clip(track: 1, frame: CGSize(width: 32, height: 16), base: CGAffineTransform(scaleX: 4, y: 4))
        let frame = try harness.draw([CompositorHarness.group([inner], effects: [turn(45)], frame: CGSize(width: 32, height: 16))])
        #expect(harness.pixel(frame, x: 16, y: 8).x > 0.8)
        #expect(harness.pixel(frame, x: 1, y: 1).x < 0.05)
        #expect(harness.pixel(frame, x: 30, y: 14).x < 0.05)
    }

    @Test func aPassThroughClipPlacesItsLayersBeforeTheyBlendWithWhatIsUnder() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0.6, 0.2, 0.4, 1))
        try harness.addSolid(track: 2, SIMD4(0.3, 0.7, 0.5, 1))
        try harness.addSolid(track: 3, SIMD4(0.8, 0.8, 0.1, 1))
        var multiply = Effect(kind: .blending)
        multiply.controls[0].blendMode = .multiply
        let move = shift(4, 2)

        // As layers of the nested timeline, drawn into the one it is in and
        // moved as a group is...
        let passing = try harness.draw([
            CompositorHarness.group(
                [CompositorHarness.clip(track: 2, effects: [multiply]), CompositorHarness.clip(track: 1)],
                effects: [move], passThrough: true
            ),
            CompositorHarness.clip(track: 3),
        ])
        // ...is the same as if each sat on the outer timeline, already moved,
        // blending with what is under it there.
        let flat = try harness.draw([
            CompositorHarness.clip(track: 2, effects: [move, multiply]),
            CompositorHarness.clip(track: 1, effects: [move]),
            CompositorHarness.clip(track: 3),
        ])
        for y in 0..<8 {
            for x in 0..<16 { #expect(close(harness.pixel(passing, x: x, y: y), harness.pixel(flat, x: x, y: y), tolerance: 0.02), "\(x),\(y)") }
        }
    }
}
