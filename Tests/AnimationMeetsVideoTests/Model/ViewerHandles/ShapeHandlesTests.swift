import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The handles of a selected shape or text block in the viewer.
@Suite struct ShapeHandlesTests {
    private let frame = CGSize(width: 1920, height: 1080)

    private func clip(_ effects: [Effect]) -> TimelineClip {
        var clip = TimelineClip(source: .graphic, startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 10, timescale: 1))
        clip.effects = effects
        return clip
    }

    private func context(_ clip: TimelineClip, _ effect: Effect, time: CMTime = .zero) -> HandleContext {
        HandleContext(clip: clip, sourceTime: time, frameSize: frame, pictureRect: CGRect(origin: .zero, size: frame), selectedEffectID: effect.id)
    }

    private func shape(_ kind: EffectKind, _ values: [(ControlKind, [Double])]) -> Effect {
        var effect = Effect(kind: kind)
        for (control, numbers) in values {
            effect.changeControl(control) { $0.number = AnimatedValue(ComponentValue(values: numbers)) }
        }
        return effect
    }

    private func close(_ a: CGPoint, _ b: CGPoint, within tolerance: Double = 0.001) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    /// The effect after dragging `part`'s handle by `delta` on screen.
    private func dragged(
        _ part: ShapeHandles.Part, by delta: CGVector, shift: Bool = false, _ effect: Effect, in effects: [Effect]? = nil
    ) throws -> Effect? {
        let ctx = context(clip(effects ?? [effect]), effect)
        let set = ShapeHandles(effectID: effect.id)
        let handle = try #require(set.handles(ctx).first { $0.id == part.handle })
        var drag = HandleDrag(handle: handle.id, start: handle.place, shift: shift)
        drag.move(to: CGPoint(x: handle.place.x + delta.dx, y: handle.place.y + delta.dy), about: nil, holdingWithin: 10)
        return set.edit(drag, ctx)?.applied(to: ctx.clip).effect(id: effect.id)
    }

    private func rectangle(linked: Bool = false) -> Effect {
        var effect = shape(.rectangle, [(.shapeSize, [640, 360]), (.shapePosition, [100, 0]), (.cornerRadius, [0])])
        effect.changeControl(.shapeSize) { $0.linked = linked }
        return effect
    }

    @Test func aSelectedShapeHasItsOwnHandlesInsteadOfTheTransforms() {
        let box = rectangle()
        let sets = ViewerHandleSets.active(for: clip([box]), on: TimelineLayer(clips: []), in: .empty, selectedEffectID: box.id)
        #expect(sets.count == 1 && sets.first is ShapeHandles)
        let handles = ShapeHandles(effectID: box.id).handles(context(clip([box]), box))
        #expect(handles.map(\.id) == ShapeHandles.Part.allCases.filter { [.center, .width, .height, .size, .corners].contains($0) }.map(\.handle))
        #expect(close(handles[0].place, CGPoint(x: 1060, y: 540)))
        #expect(close(handles[1].place, CGPoint(x: 1380, y: 540)))
        #expect(close(handles[2].place, CGPoint(x: 1060, y: 720)))
        #expect(close(handles[4].place, CGPoint(x: 740, y: 360)))
    }

    @Test func theEdgesAndCornerSetTheSize() throws {
        #expect(try dragged(.width, by: CGVector(dx: 50, dy: 9), rectangle())?.control(.shapeSize)?.values(at: .zero) == [740, 360])
        #expect(try dragged(.height, by: CGVector(dx: 0, dy: -30), rectangle())?.control(.shapeSize)?.values(at: .zero) == [640, 300])
        #expect(try dragged(.size, by: CGVector(dx: 10, dy: 20), rectangle())?.control(.shapeSize)?.values(at: .zero) == [660, 400])
        // With Shift the corner keeps the proportion.
        let even = try dragged(.size, by: CGVector(dx: 64, dy: 36), shift: true, rectangle())?.control(.shapeSize)?.values(at: .zero)
        #expect(even == [768, 432])
    }

    @Test func aLinkedSizeKeepsItsProportionFromAnEdge() throws {
        let size = try dragged(.width, by: CGVector(dx: 50, dy: 0), rectangle(linked: true))?.control(.shapeSize)?.values(at: .zero) ?? []
        #expect(size.first == 740 && abs((size.last ?? 0) - 416.25) < 1e-9)
    }

    @Test func theCenterMovesThePosition() throws {
        #expect(try dragged(.center, by: CGVector(dx: -40, dy: 25), rectangle())?.control(.shapePosition)?.values(at: .zero) == [60, 25])
        #expect(try dragged(.center, by: CGVector(dx: -40, dy: 25), shift: true, rectangle())?.control(.shapePosition)?.values(at: .zero) == [60, 0])
    }

    @Test func theCornersRunAlongTheTopEdge() throws {
        #expect(try dragged(.corners, by: CGVector(dx: 30, dy: 5), rectangle())?.control(.cornerRadius)?.values(at: .zero) == [30])
        // No rounder than half the shorter side.
        #expect(try dragged(.corners, by: CGVector(dx: 900, dy: 0), rectangle())?.control(.cornerRadius)?.values(at: .zero) == [180])
    }

    @Test func aPolygonsPointSetsItsRadiusAndTurn() throws {
        let hexagon = shape(.polygon, [(.radius, [180]), (.shapeRotation, [0]), (.shapePosition, [0, 0]), (.points, [6])])
        let handles = ShapeHandles(effectID: hexagon.id).handles(context(clip([hexagon]), hexagon))
        #expect(handles.first { $0.id == ShapeHandles.Part.radius.handle }.map { close($0.place, CGPoint(x: 960, y: 360)) } == true)
        // From straight up to straight right: a quarter clockwise.
        let turned = try dragged(.radius, by: CGVector(dx: 180, dy: 180), hexagon)
        #expect(turned?.control(.radius)?.values(at: .zero) == [180])
        #expect(turned?.control(.shapeRotation)?.values(at: .zero) == [90])
        // Shift keeps the turn.
        let grown = try dragged(.radius, by: CGVector(dx: 180, dy: 180), shift: true, hexagon)
        #expect(grown?.control(.shapeRotation)?.values(at: .zero) == [0])
    }

    @Test func aStarsNotchSetsItsInnerRadius() throws {
        let star = shape(.star, [(.radius, [180]), (.innerRadius, [90]), (.shapeRotation, [0]), (.shapePosition, [0, 0]), (.points, [5])])
        let angle = -Double.pi / 2 + .pi / 5
        let out = try dragged(.inner, by: CGVector(dx: 10 * cos(angle), dy: 10 * sin(angle)), star)
        #expect(out?.control(.innerRadius)?.values(at: .zero) == [100])
    }

    @Test func handlesFollowATransformBelowTheShape() {
        let box = rectangle()
        var below = Effect(kind: .transform)
        below.changeControl(.scale) { $0.number = AnimatedValue(ComponentValue(values: [50, 50])) }
        let handles = ShapeHandles(effectID: box.id).handles(context(clip([box, below]), box))
        // Half as far from the anchor, which on a graphic clip is the
        // middle of its first shape.
        #expect(close(handles[1].place, CGPoint(x: 1220, y: 540)))
    }

    @Test func aTextBlocksWrapWidthHandleIsOnItsFreeEdge() throws {
        var text = Effect(kind: .text)
        text.text = TextContent(string: "Wrap me")
        let ctx = context(clip([text]), text)
        let set = ShapeHandles(effectID: text.id)
        let handle = try #require(set.handles(ctx).first { $0.id == ShapeHandles.Part.wrap.handle })
        #expect(handle.place.x > 960)
        let width = try #require(set.keyTargets(ctx).first { $0.handle == ShapeHandles.Part.wrap.handle })
        #expect(width.value == "None")
        var drag = HandleDrag(handle: handle.id, start: handle.place)
        drag.move(to: CGPoint(x: handle.place.x + 20, y: handle.place.y), about: nil, holdingWithin: 10)
        let wrapped = set.edit(drag, ctx)?.applied(to: ctx.clip).effect(id: text.id)?.control(.wrapWidth)?.values(at: .zero).first ?? 0
        // Centered: the right edge moves half as far as the block widens.
        let natural = Double(handle.place.x - 960) * 2
        #expect(abs(wrapped - (natural + 40).rounded()) <= 1)
    }

    @Test func anAnimatedSizeGetsAKeyframeAndResetGoesBack() throws {
        var box = rectangle()
        box.changeControl(.shapeSize) { $0.number.setAnimated(true, at: .zero) }
        let time = CMTime(value: 2, timescale: 1)
        let ctx = context(clip([box]), box, time: time)
        let set = ShapeHandles(effectID: box.id)
        let grown = set.nudge(ShapeHandles.Part.width.handle, .up, step: .large, ctx)?.applied(to: ctx.clip).effect(id: box.id)
        #expect(grown?.control(.shapeSize)?.number.keyframe(at: time)?.value.values == [650, 360])
        let rounded = shape(.rectangle, [(.shapeSize, [640, 360]), (.cornerRadius, [40])])
        let square = ShapeHandles(effectID: rounded.id).reset(ShapeHandles.Part.corners.handle, context(clip([rounded]), rounded))
        #expect(square?.applied(to: clip([rounded])).effect(id: rounded.id)?.control(.cornerRadius)?.values(at: .zero) == [0])
        #expect(set.reset(ShapeHandles.Part.corners.handle, ctx) == nil)
    }
}
