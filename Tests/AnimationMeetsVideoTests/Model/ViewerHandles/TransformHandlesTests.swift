import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private let frame = CGSize(width: 1920, height: 1080)
private let full = CGRect(origin: .zero, size: frame)

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

/// A Transform effect with these controls set; the rest at their defaults.
private func transform(_ values: [(ControlKind, [Double])] = []) -> Effect {
    var effect = Effect(kind: .transform)
    for (kind, numbers) in values {
        effect.changeControl(kind) { $0.number = AnimatedValue(ComponentValue(values: numbers)) }
    }
    return effect
}

private func clip(_ effects: [Effect] = [], anchor: Vector2 = .zero) -> TimelineClip {
    var clip = TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: seconds(10))
    clip.effects = effects
    clip.anchorPoint = AnimatedValue(anchor)
    return clip
}

private func context(_ clip: TimelineClip, rect: CGRect = full, time: CMTime = .zero, selected: UUID? = nil) -> HandleContext {
    HandleContext(clip: clip, sourceTime: time, frameSize: frame, pictureRect: rect, selectedEffectID: selected)
}

private func close(_ a: CGPoint, _ b: CGPoint, within tolerance: Double = 0.001) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

private func close(_ a: Double, _ b: Double, within tolerance: Double = 0.001) -> Bool {
    abs(a - b) <= tolerance
}

private let handles = TransformHandles()

/// The clip after dragging `handle` from `start` to `end`.
private func dragged(
    _ handle: HandleID, from start: CGPoint, to end: CGPoint, shift: Bool = false, option: Bool = false, in context: HandleContext
) -> (clip: TimelineClip, edit: HandleEdit?) {
    var drag = HandleDrag(handle: handle, start: start, shift: shift, option: option)
    drag.move(to: end, about: handles.pivot(of: handle, context), holdingWithin: 10)
    let edit = handles.edit(drag, context)
    return (edit?.applied(to: context.clip) ?? context.clip, edit)
}

private func values(_ kind: ControlKind, of clip: TimelineClip, effect index: Int = 0, at time: CMTime = .zero) -> [Double] {
    clip.effects[index].control(kind)?.values(at: time) ?? []
}

private func placement(_ clip: TimelineClip, _ context: HandleContext) -> FoldedPlacement {
    var context = context
    context.clip = clip
    return TransformHandles.fold(clip, context)
}

// MARK: - The box

@Suite struct TransformHandlesBoxTests {
    @Test func footageOfAnotherShapeIsFittedAndCentered() {
        let rect = TransformHandles.pictureRect(
            of: clip(), in: .empty, frameSize: frame, pictureSize: CGSize(width: 1000, height: 1000), at: .zero
        )
        #expect(close(rect.origin, CGPoint(x: 420, y: 0)))
        #expect(close(rect.width, 1080) && close(rect.height, 1080))
    }

    @Test func footageOfUnknownSizeIsTheFrame() {
        #expect(TransformHandles.pictureRect(of: clip(), in: .empty, frameSize: frame, pictureSize: nil, at: .zero) == full)
    }

    @Test func anEllipseHasTheRectangleRoundIt() {
        var ellipse = Effect(kind: .ellipse)
        ellipse.changeControl(.shapeSize) { $0.number = AnimatedValue(ComponentValue(values: [400, 200])) }
        ellipse.changeControl(.shapePosition) { $0.number = AnimatedValue(ComponentValue(values: [100, 0])) }
        var graphic = clip([ellipse])
        graphic.source = .graphic
        let rect = TransformHandles.pictureRect(of: graphic, in: .empty, frameSize: frame, pictureSize: nil, at: .zero)
        #expect(close(rect.origin, CGPoint(x: 860, y: 440), within: 0.5))
        #expect(close(rect.width, 400, within: 0.5) && close(rect.height, 200, within: 0.5))
    }

    @Test func aGraphicClipDrawingNothingIsTheFrame() {
        var graphic = clip()
        graphic.source = .graphic
        #expect(TransformHandles.pictureRect(of: graphic, in: .empty, frameSize: frame, pictureSize: nil, at: .zero) == full)
    }

    @Test func theBoxIsTheRectangleThroughTheFold() {
        let turned = clip([transform([(.rotation, [90])])])
        let outline = handles.outlines(context(turned))
        #expect(outline.count == 1)
        // The top left corner turns about the middle, to the top right of
        // a box standing on end.
        #expect(close(outline[0].points[0], CGPoint(x: 1500, y: -420)))
    }

    @Test func eightScaleHandlesAnAnchorAndEightZones() {
        let all = handles.handles(context(clip()))
        #expect(all.filter { if case .scale = $0.id { true } else { false } }.count == 8)
        #expect(all.filter { if case .rotate = $0.id { true } else { false } }.count == 8)
        #expect(all.contains { $0.id == .anchor && close($0.place, CGPoint(x: 960, y: 540)) })
    }

    @Test func aShortEdgeHasNoMiddleHandle() {
        let small = context(clip(), rect: CGRect(x: 950, y: 500, width: 20, height: 80))
        let ids = handles.handles(small).map(\.id)
        #expect(!ids.contains(.scale(.top)) && !ids.contains(.scale(.bottom)))
        #expect(ids.contains(.scale(.left)) && ids.contains(.scale(.right)))
        // Zoomed in four times, the top edge is 80 points long.
        var zoomed = small
        zoomed.pixelsPerPoint = 0.25
        #expect(handles.handles(zoomed).map(\.id).contains(.scale(.top)))
    }

    @Test func aLockedClipHasItsBoxButNoHandles() {
        var locked = context(clip())
        locked.isLocked = true
        #expect(handles.handles(locked).isEmpty)
        #expect(handles.outlines(locked).count == 1)
    }

    @Test func insideTheBoxMoves() {
        let ctx = context(clip())
        #expect(handles.area(at: CGPoint(x: 100, y: 100), ctx) == .move)
        #expect(handles.area(at: CGPoint(x: -10, y: 100), ctx) == nil)
    }

    @Test func aRotationZoneIsOutsideTheBox() {
        let ctx = context(clip())
        let found = HandleHitTest.handle(at: CGPoint(x: 1935, y: -10), in: handles.handles(ctx)) { $0 }
        #expect(found?.id == .rotate(.topRight))
        let inside = HandleHitTest.handle(at: CGPoint(x: 1900, y: 15), in: handles.handles(ctx)) { $0 }
        #expect(inside == nil)
        let onHandle = HandleHitTest.handle(at: CGPoint(x: 1918, y: 2), in: handles.handles(ctx)) { $0 }
        #expect(onHandle?.id == .scale(.topRight))
    }
}

// MARK: - Dragging

@Suite struct TransformHandlesDragTests {
    @Test func movingFollowsThePointerInWholePixels() {
        let ctx = context(clip([transform()]))
        let (moved, edit) = dragged(.move, from: CGPoint(x: 960, y: 540), to: CGPoint(x: 1080.4, y: 499.7), in: ctx)
        #expect(values(.position, of: moved) == [120, -40])
        #expect(edit?.readout == "120, \u{2212}40")
        #expect(edit?.actionName == "Move")
    }

    @Test func shiftKeepsAMoveToTheNearerAxis() {
        let ctx = context(clip([transform()]))
        #expect(values(.position, of: dragged(.move, from: .zero, to: CGPoint(x: 100, y: 40), shift: true, in: ctx).clip) == [100, 0])
        #expect(values(.position, of: dragged(.move, from: .zero, to: CGPoint(x: 40, y: 100), shift: true, in: ctx).clip) == [0, 100])
    }

    @Test func aMoveKeepsTheGrabbedSpotUnderThePointerWithATransformAfterIt() {
        let first = transform()
        let second = transform([(.scale, [200, 200]), (.rotation, [30])])
        let ctx = context(clip([first, second]), selected: first.id)
        let start = CGPoint(x: 1200, y: 600), end = CGPoint(x: 1350, y: 520)
        let grabbed = start.applying(placement(ctx.clip, ctx).matrix.inverted())
        let (moved, _) = dragged(.move, from: start, to: end, in: ctx)
        #expect(values(.position, of: moved, effect: 1) == [0, 0])
        #expect(close(grabbed.applying(placement(moved, ctx).matrix), end, within: 1.5))
    }

    @Test func aDragThatChangesNothingEditsNothing() {
        let ctx = context(clip())
        #expect(dragged(.move, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10.2, y: 10.1), in: ctx).edit == nil)
    }

    @Test func aCornerScalesInProportionAboutTheAnchor() {
        let ctx = context(clip([transform([(.scale, [100, 50])])]))
        let corner = TransformHandles.screen(.bottomRight, placement(ctx.clip, ctx), full)
        // Along the line from the anchor (the middle) through the corner.
        let end = CGPoint(x: 960 + (corner.x - 960) * 1.5, y: 540 + (corner.y - 540) * 1.5)
        let (scaled, edit) = dragged(.scale(.bottomRight), from: corner, to: end, in: ctx)
        #expect(values(.scale, of: scaled) == [150, 75])
        #expect(values(.position, of: scaled) == [0, 0])
        #expect(close(placement(scaled, ctx).anchor, CGPoint(x: 960, y: 540)))
        #expect(edit?.readout == "150% \u{00D7} 75%")
    }

    @Test func shiftFreesACorner() {
        let ctx = context(clip([transform()]))
        let (scaled, _) = dragged(.scale(.bottomRight), from: CGPoint(x: 1920, y: 1080), to: CGPoint(x: 2400, y: 1080), shift: true, in: ctx)
        #expect(values(.scale, of: scaled) == [150, 100])
        #expect(scaled.effects[0].control(.scale)?.linked == false)
        // The corner is under the pointer.
        #expect(close(TransformHandles.screen(.bottomRight, placement(scaled, ctx), full), CGPoint(x: 2400, y: 1080)))
    }

    @Test func anEdgeScalesItsOneAxis() {
        let ctx = context(clip([transform()]))
        let (scaled, _) = dragged(.scale(.right), from: CGPoint(x: 1920, y: 540), to: CGPoint(x: 2400, y: 640), in: ctx)
        #expect(values(.scale, of: scaled) == [150, 100])
        #expect(scaled.effects[0].control(.scale)?.linked == false)
        let (bottom, _) = dragged(.scale(.bottom), from: CGPoint(x: 960, y: 1080), to: CGPoint(x: 900, y: 810), in: ctx)
        #expect(values(.scale, of: bottom) == [100, 50])
    }

    @Test func shiftMakesAnEdgeProportional() {
        let ctx = context(clip([transform()]))
        let (scaled, _) = dragged(.scale(.right), from: CGPoint(x: 1920, y: 540), to: CGPoint(x: 2400, y: 540), shift: true, in: ctx)
        #expect(values(.scale, of: scaled) == [150, 150])
        #expect(scaled.effects[0].control(.scale)?.linked == true)
    }

    @Test func scalingWithTheAnchorOnACornerKeepsThatCornerStill() {
        let ctx = context(clip([transform()], anchor: Vector2(x: -960, y: -540)))
        let (scaled, _) = dragged(.scale(.bottomRight), from: CGPoint(x: 1920, y: 1080), to: CGPoint(x: 2880, y: 1620), in: ctx)
        #expect(values(.scale, of: scaled) == [150, 150])
        #expect(values(.position, of: scaled) == [0, 0])
        #expect(close(TransformHandles.screen(.topLeft, placement(scaled, ctx), full), .zero))
    }

    @Test func scalingWithTheAnchorOutsideTheBoxSwingsAwayFromIt() {
        let ctx = context(clip([transform()], anchor: Vector2(x: -1500, y: 0)))
        let anchor = CGPoint(x: -540, y: 540)
        let corner = CGPoint(x: 1920, y: 1080)
        let end = CGPoint(x: anchor.x + (corner.x - anchor.x) * 2, y: anchor.y + (corner.y - anchor.y) * 2)
        let (scaled, _) = dragged(.scale(.bottomRight), from: corner, to: end, in: ctx)
        #expect(values(.scale, of: scaled) == [200, 200])
        #expect(close(placement(scaled, ctx).anchor, anchor))
    }

    @Test func aScaleAcrossTheAnchorFlips() {
        let ctx = context(clip([transform()]))
        let (scaled, _) = dragged(.scale(.right), from: CGPoint(x: 1920, y: 540), to: CGPoint(x: 0, y: 540), in: ctx)
        #expect(values(.scale, of: scaled) == [-100, 100])
    }

    @Test func handlesWithoutALeverAreDimmed() {
        // The anchor on the bottom right corner: that handle has no lever.
        let cornered = handles.handles(context(clip([transform()], anchor: Vector2(x: 960, y: 540))))
        #expect(cornered.first { $0.id == .scale(.bottomRight) }?.isEnabled == false)
        #expect(cornered.first { $0.id == .scale(.topLeft) }?.isEnabled == true)
        // On the top edge: the top handle is level with it, the others work.
        let edged = handles.handles(context(clip([transform()], anchor: Vector2(x: 0, y: -540))))
        #expect(edged.first { $0.id == .scale(.top) }?.isEnabled == false)
        #expect(edged.first { $0.id == .scale(.bottom) }?.isEnabled == true)
        #expect(edged.first { $0.id == .scale(.left) }?.isEnabled == true)
    }

    @Test func aDrivenControlsHandlesAreRefused() {
        let target = transform()
        var driver = Effect(kind: .audioKeys)
        driver.keyframing?.target = .control(effectID: target.id, controlID: target.control(.scale)!.id)
        let all = handles.handles(context(clip([driver, target])))
        let corner = all.first { $0.id == .scale(.topLeft) }
        #expect(corner?.isEnabled == false)
        if case .driven(let keyframing, _, _)? = corner?.refusal { #expect(keyframing == driver.id) } else { Issue.record("not refused") }
        #expect(all.first { $0.id == .rotate(.topLeft) }?.isEnabled == true)
    }
}

// MARK: - Turning

@Suite struct TransformHandlesRotationTests {
    /// A drag round `pivot` from `start` through `turns` of a circle, in
    /// steps, as the pointer would go.
    private func turn(_ handle: HandleID, from start: CGPoint, about pivot: CGPoint, by turns: Double, shift: Bool = false, in context: HandleContext) -> HandleEdit? {
        var drag = HandleDrag(handle: handle, start: start, shift: shift)
        let radius = hypot(start.x - pivot.x, start.y - pivot.y)
        let first = atan2(start.y - pivot.y, start.x - pivot.x)
        let steps = max(Int(abs(turns) * 72), 1)
        for step in 1...steps {
            let angle = first + 2 * .pi * turns * Double(step) / Double(steps)
            drag.move(to: CGPoint(x: pivot.x + radius * cos(angle), y: pivot.y + radius * sin(angle)), about: pivot, holdingWithin: 10)
        }
        return handles.edit(drag, context)
    }

    @Test func aCornerZoneTurnsWithThePointer() {
        let ctx = context(clip([transform()]))
        let edit = turn(.rotate(.topRight), from: CGPoint(x: 1930, y: -10), about: CGPoint(x: 960, y: 540), by: 0.25, in: ctx)
        let turned = edit.map { $0.applied(to: ctx.clip) }
        #expect(turned.map { values(.rotation, of: $0) } == [90])
        #expect(edit?.readout == "90.0\u{00B0}")
    }

    @Test func anEdgeZoneNearTheAnchorTurnsToo() {
        let ctx = context(clip([transform()], anchor: Vector2(x: 0, y: -500)))
        let edit = turn(.rotate(.top), from: CGPoint(x: 960, y: -10), about: CGPoint(x: 960, y: 40), by: -0.125, in: ctx)
        #expect(edit.map { values(.rotation, of: $0.applied(to: ctx.clip)) } == [-45])
    }

    @Test func turnsPastAFullOneAreKept() {
        let ctx = context(clip([transform()]))
        let edit = turn(.rotate(.bottomLeft), from: CGPoint(x: -10, y: 1090), about: CGPoint(x: 960, y: 540), by: 2, in: ctx)
        #expect(edit.map { values(.rotation, of: $0.applied(to: ctx.clip)) } == [720])
    }

    @Test func aFlippedClipStillFollowsThePointer() {
        // Rotation above a flip: more Rotation turns the picture the other
        // way on screen.
        var flip = EffectControl(kind: .scale)
        flip.number = AnimatedValue(ComponentValue(values: [-100, 100]))
        let effect = Effect(kind: .transform, controls: [EffectControl(kind: .rotation), flip])
        let ctx = context(clip([effect]))
        let edit = turn(.rotate(.topRight), from: CGPoint(x: 1930, y: -10), about: CGPoint(x: 960, y: 540), by: 0.25, in: ctx)
        let turned = edit.map { $0.applied(to: ctx.clip) }
        #expect(turned.map { values(.rotation, of: $0) } == [-90])
        // The grabbed corner went the way the pointer did: clockwise.
        let grabbed = TransformHandles.screen(.topLeft, placement(ctx.clip, ctx), full)
        #expect(close(grabbed, CGPoint(x: 1920, y: 0)))
        if let turned {
            #expect(close(TransformHandles.screen(.topLeft, placement(turned, ctx), full), CGPoint(x: 1500, y: 1500)))
        }
    }

    @Test func theAngleHoldsNearTheAnchor() {
        let pivot = CGPoint(x: 960, y: 540)
        var drag = HandleDrag(handle: .rotate(.topRight), start: CGPoint(x: 1060, y: 540))
        drag.move(to: CGPoint(x: 960, y: 640), about: pivot, holdingWithin: 10)
        #expect(close(drag.swept, .pi / 2))
        // Through the middle and out the other side: nothing for that.
        drag.move(to: CGPoint(x: 962, y: 541), about: pivot, holdingWithin: 10)
        drag.move(to: CGPoint(x: 860, y: 540), about: pivot, holdingWithin: 10)
        #expect(close(drag.swept, .pi / 2))
        drag.move(to: CGPoint(x: 960, y: 440), about: pivot, holdingWithin: 10)
        #expect(close(drag.swept, .pi))
    }

    @Test func shiftSnapsTheValueToFifteenDegrees() {
        let ctx = context(clip([transform([(.rotation, [7])])]))
        let edit = turn(.rotate(.topRight), from: CGPoint(x: 1930, y: -10), about: CGPoint(x: 960, y: 540), by: 0.004, shift: true, in: ctx)
        #expect(edit.map { values(.rotation, of: $0.applied(to: ctx.clip)) } == [15])
    }
}

// MARK: - The anchor

@Suite struct TransformHandlesAnchorTests {
    @Test func movingTheAnchorKeepsAScaledTurnedPictureStill() {
        let ctx = context(clip([transform([(.scale, [200, 150]), (.rotation, [30]), (.position, [40, -20])])]))
        let before = TransformHandles.corners(placement(ctx.clip, ctx), full)
        let anchor = placement(ctx.clip, ctx).anchor
        let (moved, edit) = dragged(.anchor, from: anchor, to: CGPoint(x: anchor.x + 300, y: anchor.y + 123), in: ctx)
        #expect(moved.anchorPoint != ctx.clip.anchorPoint)
        #expect(values(.position, of: moved) != [40, -20])
        for (a, b) in zip(before, TransformHandles.corners(placement(moved, ctx), full)) { #expect(close(a, b, within: 0.01)) }
        #expect(close(placement(moved, ctx).anchor, CGPoint(x: anchor.x + 300, y: anchor.y + 123), within: 2))
        #expect(edit?.actionName == "Move Anchor Point")
    }

    @Test func onAPlainClipOnlyTheAnchorChanges() {
        let bare = context(clip())
        let (moved, _) = dragged(.anchor, from: CGPoint(x: 960, y: 540), to: CGPoint(x: 1000, y: 500), in: bare)
        #expect(moved.anchorPoint.value == Vector2(x: 40, y: -40))
        #expect(moved.effects.isEmpty)
        let plain = context(clip([transform()]))
        let (alone, _) = dragged(.anchor, from: CGPoint(x: 960, y: 540), to: CGPoint(x: 1000, y: 500), in: plain)
        #expect(alone.anchorPoint.value == Vector2(x: 40, y: -40))
        #expect(alone.effects == plain.clip.effects)
    }

    @Test func shiftMovesTheAnchorByTensAndOptionByTenths() {
        let ctx = context(clip())
        let tens = dragged(.anchor, from: CGPoint(x: 960, y: 540), to: CGPoint(x: 1003, y: 517), shift: true, in: ctx).clip
        #expect(tens.anchorPoint.value == Vector2(x: 40, y: -20))
        let tenths = dragged(.anchor, from: CGPoint(x: 960, y: 540), to: CGPoint(x: 973, y: 540), option: true, in: ctx).clip
        #expect(close(tenths.anchorPoint.value.x, 1.3) && tenths.anchorPoint.value.y == 0)
    }

    @Test func theAnchorCatchesOnTheBoxsPoints() {
        let ctx = context(clip())
        for point in BoxPoint.allCases where point != .center {
            let spot = point.point(in: full)
            let (moved, edit) = dragged(.anchor, from: CGPoint(x: 960, y: 540), to: CGPoint(x: spot.x + 5, y: spot.y - 4), in: ctx)
            #expect(moved.anchorPoint.value == Vector2(x: spot.x - 960, y: spot.y - 540))
            #expect(edit?.readout.hasSuffix(point.shortName) == true)
        }
        let loose = dragged(.anchor, from: CGPoint(x: 960, y: 540), to: CGPoint(x: 1925, y: -4), option: true, in: ctx).clip
        #expect(loose.anchorPoint.value != Vector2(x: 960, y: -540))
    }

    @Test func aDoubleClickPutsTheAnchorBackInTheMiddle() {
        let ctx = context(clip([transform([(.scale, [50, 50])])], anchor: Vector2(x: 300, y: 100)))
        let before = TransformHandles.corners(placement(ctx.clip, ctx), full)
        let reset = TransformHandles.resetAnchor(ctx).map { $0.applied(to: ctx.clip) }
        #expect(reset?.anchorPoint.value == .zero)
        if let reset {
            for (a, b) in zip(before, TransformHandles.corners(placement(reset, ctx), full)) { #expect(close(a, b, within: 0.01)) }
        }
    }

    @Test func aScaledToNothingClipsAnchorIsDimmed() {
        let all = handles.handles(context(clip([transform([(.scale, [0, 0])])])))
        #expect(all.first { $0.id == .anchor }?.isEnabled == false)
    }

    @Test func theAnchorsHoverTextSaysWhereItIs() {
        let all = handles.handles(context(clip(anchor: Vector2(x: 120, y: -40))))
        #expect(all.first { $0.id == .anchor }?.hoverText == "Anchor 120, \u{2212}40")
    }
}

// MARK: - Keyframes

@Suite struct TransformHandlesKeyframeTests {
    private func animated(_ kind: ControlKind, in effect: Effect, _ keyframes: [(Double, [Double])]) -> Effect {
        var effect = effect
        effect.changeControl(kind) { control in
            control.number.setAnimated(true, at: seconds(keyframes[0].0))
            for (time, numbers) in keyframes { control.number.set(ComponentValue(values: numbers), at: seconds(time)) }
        }
        return effect
    }

    @Test func eachDragAddsAKeyframeOnlyWhereTheValueIsAnimated() {
        let time = seconds(2)
        let still = context(clip([transform()]), time: time)
        let moved = dragged(.move, from: .zero, to: CGPoint(x: 10, y: 0), in: still).clip
        #expect(moved.effects[0].control(.position)?.isAnimated == false)

        let effect = animated(.position, in: transform(), [(0, [0, 0]), (4, [100, 0])])
        let keyed = context(clip([effect]), time: time)
        let after = dragged(.move, from: .zero, to: CGPoint(x: 10, y: 0), in: keyed).clip
        let position = after.effects[0].control(.position)!
        #expect(position.number.keyframes.count == 3)
        #expect(position.number.keyframe(at: time)?.value.values == [60, 0])
        // Nothing else was written.
        #expect(after.effects[0].control(.scale) == effect.control(.scale))
        #expect(after.anchorPoint == keyed.clip.anchorPoint)
    }

    @Test func scaleRotationAndOpacityKeyframeWhereAnimated() {
        let time = seconds(1)
        var effect = animated(.scale, in: transform(), [(0, [100, 100]), (3, [100, 100])])
        effect = animated(.rotation, in: effect, [(0, [0]), (3, [0])])
        effect = animated(.opacity, in: effect, [(0, [100]), (3, [100])])
        let ctx = context(clip([effect]), time: time)
        let scaled = dragged(.scale(.bottomRight), from: CGPoint(x: 1920, y: 1080), to: CGPoint(x: 2400, y: 1350), in: ctx).clip
        #expect(scaled.effects[0].control(.scale)?.number.keyframe(at: time) != nil)
        let faded = handles.nudge(.opacity, .left, step: .large, ctx)?.applied(to: ctx.clip)
        #expect(faded?.effects[0].control(.opacity)?.number.keyframe(at: time)?.value.values == [90])
        let turned = handles.nudge(.rotate(.top), .right, step: .normal, ctx)?.applied(to: ctx.clip)
        #expect(turned?.effects[0].control(.rotation)?.number.keyframe(at: time)?.value.values == [1])
    }

    @Test func anAnimatedAnchorGetsAKeyframe() {
        let time = seconds(1)
        var keyed = clip()
        keyed.anchorPoint.setAnimated(true, at: .zero)
        let ctx = context(keyed, time: time)
        let moved = dragged(.anchor, from: CGPoint(x: 960, y: 540), to: CGPoint(x: 1000, y: 540), in: ctx).clip
        #expect(moved.anchorPoint.keyframes.count == 2)
        #expect(moved.anchorPoint.keyframe(at: time)?.value == Vector2(x: 40, y: 0))
    }

    @Test func anAnchorDragShiftsEveryPositionKeyframeAlike() {
        var effect = transform([(.scale, [200, 200])])
        effect = animated(.position, in: effect, [(0, [0, 0]), (2, [100, 50]), (4, [-80, 10])])
        let ctx = context(clip([effect]), time: seconds(2))
        let (moved, _) = dragged(.anchor, from: CGPoint(x: 1060, y: 590), to: CGPoint(x: 1160, y: 590), in: ctx)
        let before = effect.control(.position)!.number.keyframes
        let after = moved.effects[0].control(.position)!.number.keyframes
        #expect(after.count == before.count)
        let shift = after[0].value.values[0] - before[0].value.values[0]
        #expect(shift != 0)
        for (a, b) in zip(before, after) {
            #expect(a.time == b.time)
            #expect(close(b.value.values[0] - a.value.values[0], shift) && close(b.value.values[1] - a.value.values[1], after[0].value.values[1] - before[0].value.values[1]))
        }
        // The box is where it was at every keyframe.
        for keyframe in before {
            var at = ctx
            at.sourceTime = keyframe.time
            let was = TransformHandles.corners(placement(ctx.clip, at), full)
            let now = TransformHandles.corners(placement(moved, at), full)
            for (a, b) in zip(was, now) { #expect(close(a, b, within: 0.01)) }
        }
    }
}

// MARK: - The target

@Suite struct TransformHandlesTargetTests {
    @Test func thePickedTransformIsTheTarget() {
        let first = transform(), second = transform()
        let ctx = context(clip([first, second]), selected: first.id)
        #expect(TransformHandles.targetIndex(in: ctx.clip, ctx) == 0)
        let unpicked = context(clip([first, second]))
        #expect(TransformHandles.targetIndex(in: unpicked.clip, unpicked) == 1)
    }

    @Test func aTransformThatIsOffIsntTheTarget() {
        var off = transform()
        off.enabled = false
        let ctx = context(clip([transform(), off]), selected: off.id)
        #expect(TransformHandles.targetIndex(in: ctx.clip, ctx) == 0)
    }

    @Test func aDragAddsATransformAboveTrailingBlending() {
        let blend = Effect(kind: .blending)
        var ctx = context(clip([Effect(kind: .ellipse), blend]))
        ctx.newTransform = TransformHandles.newTransform(for: ctx.clip)
        let moved = dragged(.move, from: .zero, to: CGPoint(x: 10, y: 0), in: ctx).clip
        #expect(moved.effects.map(\.kind) == [.ellipse, .transform, .blending])
        #expect(moved.effects[1].id == ctx.newTransform?.id)
        #expect(values(.position, of: moved, effect: 1) == [10, 0])
        // The same effect each step.
        let again = dragged(.move, from: .zero, to: CGPoint(x: 20, y: 0), in: ctx).clip
        #expect(again.effects[1].id == moved.effects[1].id)
    }

    @Test func pressingAddsNothing() {
        let ctx = context(clip())
        #expect(dragged(.scale(.topLeft), from: .zero, to: .zero, in: ctx).edit == nil)
    }

    @Test func aMissingControlIsPutBackAndOneSwitchedOffIsSwitchedOn() {
        var effect = transform()
        effect.controls.removeAll { $0.kind == .scale }
        effect.changeControl(.rotation) { $0.enabled = false }
        let ctx = context(clip([effect]))
        let scaled = dragged(.scale(.bottomRight), from: CGPoint(x: 1920, y: 1080), to: CGPoint(x: 2400, y: 1350), in: ctx).clip
        #expect(values(.scale, of: scaled) == [150, 150])
        let turned = handles.nudge(.rotate(.top), .right, step: .normal, ctx)?.applied(to: ctx.clip)
        #expect(turned?.effects[0].control(.rotation)?.enabled == true)
    }

    @Test func showUpToHereCutsTheStackShort() {
        let first = transform([(.position, [100, 0])])
        let second = transform([(.position, [0, 100])])
        var ctx = context(clip([first, second]))
        ctx.shownUpTo = first.id
        #expect(TransformHandles.targetIndex(in: ctx.clip, ctx) == 0)
        #expect(close(TransformHandles.fold(ctx.clip, ctx).anchor, CGPoint(x: 1060, y: 540)))
    }

    @Test func nudgesStepEachPart() {
        let ctx = context(clip([transform()]))
        func after(_ handle: HandleID, _ direction: NudgeDirection, _ step: NudgeStep = .normal) -> TimelineClip? {
            handles.nudge(handle, direction, step: step, ctx)?.applied(to: ctx.clip)
        }
        #expect(after(.move, .right).map { values(.position, of: $0) } == [1, 0])
        #expect(after(.move, .up, .large).map { values(.position, of: $0) } == [0, -10])
        #expect(after(.scale(.bottomRight), .up).map { values(.scale, of: $0) } == [101, 101])
        #expect(after(.rotate(.top), .down).map { values(.rotation, of: $0) } == [1])
        #expect(after(.rotate(.top), .left, .large).map { values(.rotation, of: $0) } == [-15])
        #expect(after(.opacity, .down).map { values(.opacity, of: $0) } == [99])
        #expect(after(.anchor, .left, .fine)?.anchorPoint.value == Vector2(x: -0.1, y: 0))
    }

    @Test func resetPutsAPartBack() {
        let ctx = context(clip([transform([(.rotation, [45])])]))
        let reset = TransformHandles.reset(.rotation, ctx)?.applied(to: ctx.clip)
        #expect(reset.map { values(.rotation, of: $0) } == [0])
        #expect(TransformHandles.reset(.scale, ctx) == nil)
    }
}

struct ClipPartsChangedTests {
    @Test func namesTheEffectsAnEditChanges() {
        let moved = transform(), still = transform()
        let before = clip([moved, still])
        var after = before
        after.effects[0].changeControl(.position) { $0.number = AnimatedValue(ComponentValue(values: [10, 20])) }
        #expect(before.partsChanged(to: after) == [moved.id])
    }

    @Test func namesTheClipWhenItsAnchorPointMoves() {
        let before = clip([transform()])
        var after = before
        after.anchorPoint = AnimatedValue(Vector2(x: 5, y: 5))
        #expect(before.partsChanged(to: after) == [before.id])
    }

    @Test func leavesOutAnEffectTheEditAdds() {
        let before = clip()
        var after = before
        after.effects.append(transform())
        #expect(before.partsChanged(to: after).isEmpty)
    }
}
