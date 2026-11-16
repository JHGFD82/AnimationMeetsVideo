import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The handles a package's point controls get in the viewer, over the
/// packages that ship.
@Suite struct PointControlHandlesTests {
    private let frame = CGSize(width: 1920, height: 1080)

    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    private func clip(_ effects: [Effect]) -> TimelineClip {
        var clip = TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: seconds(10))
        clip.effects = effects
        return clip
    }

    private func context(_ clip: TimelineClip, selected: UUID?, time: CMTime = .zero) -> HandleContext {
        HandleContext(clip: clip, sourceTime: time, frameSize: frame, pictureRect: CGRect(origin: .zero, size: frame), selectedEffectID: selected)
    }

    private func spotlight(center: [Double] = [0, 0]) -> Effect {
        var effect = Effect(kind: EffectKind(package: "spotlight"))
        effect.changeControl(ControlKind(package: "spotlight", control: "spotCenter")) {
            $0.number = AnimatedValue(ComponentValue(values: center))
        }
        return effect
    }

    private func transform(_ values: [(ControlKind, [Double])]) -> Effect {
        var effect = Effect(kind: .transform)
        for (kind, numbers) in values {
            effect.changeControl(kind) { $0.number = AnimatedValue(ComponentValue(values: numbers)) }
        }
        return effect
    }

    private func close(_ a: CGPoint, _ b: CGPoint, within tolerance: Double = 0.001) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    private func center(of clip: TimelineClip, _ effect: Effect) -> [Double]? {
        clip.effect(id: effect.id)?.control(ControlKind(package: "spotlight", control: "spotCenter"))?.values(at: .zero)
    }

    @Test func everyShippedPointGetsAHandle() {
        let kinds = EffectKind.all.filter { $0.controlKinds.contains(where: \.hasViewerHandle) }
        // Spotlight, the masks, Twirl, Zoom Blur, Lens Flare and the rest.
        #expect(kinds.count >= 18)
        for kind in kinds {
            let effect = Effect(kind: kind)
            let handles = PointControlHandles(effectID: effect.id).handles(context(clip([effect]), selected: effect.id))
            #expect(handles.count == kind.controlKinds.filter(\.hasViewerHandle).count, "\(kind.rawValue)")
            #expect(handles.allSatisfy { $0.glyph == .round }, "\(kind.rawValue)")
        }
        let corners = Effect(kind: EffectKind(package: "fourPointMask"))
        #expect(PointControlHandles(effectID: corners.id).handles(context(clip([corners]), selected: corners.id)).count == 4)
    }

    @Test func theSelectedEffectsPointsTakeThePlaceOfTheTransformHandles() {
        let light = spotlight()
        var picked = clip([light])
        // A clip with pictures in an empty project: a graphic one.
        picked.source = .graphic
        let layer = TimelineLayer(clips: [picked])
        let sets = ViewerHandleSets.active(for: picked, on: layer, in: .empty, selectedEffectID: light.id)
        #expect(sets.first is PointControlHandles && !sets.contains { $0 is TransformHandles })
        #expect(ViewerHandleSets.active(for: picked, on: layer, in: .empty, selectedEffectID: nil).first is TransformHandles)
    }

    @Test func aPointIsAnOffsetFromTheMiddleWithDownPositive() {
        let light = spotlight(center: [200, -100])
        let handle = PointControlHandles(effectID: light.id).handles(context(clip([light]), selected: light.id)).first
        #expect(handle.map { close($0.place, CGPoint(x: 1160, y: 440)) } == true)
        #expect(handle?.value == "200, \u{2212}100")
    }

    @Test func aTransformBelowTheEffectMovesItsHandleOneAboveDoesnt() {
        let light = spotlight(center: [200, 0])
        let below = transform([(.scale, [50, 50]), (.position, [0, 100])])
        let afterIt = PointControlHandles(effectID: light.id).handles(context(clip([light, below]), selected: light.id)).first
        #expect(afterIt.map { close($0.place, CGPoint(x: 1060, y: 640)) } == true)
        let above = transform([(.position, [300, 0])])
        let beforeIt = PointControlHandles(effectID: light.id).handles(context(clip([above, light]), selected: light.id)).first
        #expect(beforeIt.map { close($0.place, CGPoint(x: 1160, y: 540)) } == true)
    }

    @Test func placementAfterUndoesWhatIsAbove() {
        let above = transform([(.scale, [200, 200]), (.rotation, [30])])
        let light = spotlight()
        let below = transform([(.position, [40, 0])])
        let effects = [above, light, below]
        let matrix = StackFolding.placement(after: 1, effects: effects, anchorPoint: AnimatedValue(.zero), at: .zero, center: CGPoint(x: 960, y: 540))
        #expect(matrix.map { close(CGPoint(x: 100, y: 100).applying($0), CGPoint(x: 140, y: 100)) } == true)
        let flat = [transform([(.scale, [0, 0])]), light]
        #expect(StackFolding.placement(after: 1, effects: flat, anchorPoint: AnimatedValue(.zero), at: .zero, center: CGPoint(x: 960, y: 540)) == nil)
    }

    @Test func draggingAPointFollowsThePointerThroughAScaleBelow() throws {
        let light = spotlight(center: [200, 0])
        let ctx = context(clip([light, transform([(.scale, [50, 50])])]), selected: light.id)
        let set = PointControlHandles(effectID: light.id)
        let handle = try #require(set.handles(ctx).first)
        var drag = HandleDrag(handle: handle.id, start: handle.place)
        drag.move(to: CGPoint(x: handle.place.x + 40, y: handle.place.y - 10), about: nil, holdingWithin: 10)
        let moved = set.edit(drag, ctx)?.applied(to: ctx.clip)
        #expect(moved.flatMap { center(of: $0, light) } == [280, -20])
        #expect(set.edit(drag, ctx)?.readout == "Center 280, \u{2212}20")
        // Shift keeps it to the nearer axis; Option a tenth, in tenths.
        drag.shift = true
        #expect(set.edit(drag, ctx).flatMap { center(of: $0.applied(to: ctx.clip), light) } == [280, 0])
        drag.shift = false
        drag.option = true
        #expect(set.edit(drag, ctx).flatMap { center(of: $0.applied(to: ctx.clip), light) } == [208, -2])
    }

    @Test func anAnimatedPointGetsAKeyframeAtThePlayhead() throws {
        var light = spotlight()
        light.changeControl(ControlKind(package: "spotlight", control: "spotCenter")) { $0.number.setAnimated(true, at: .zero) }
        let time = seconds(2)
        let ctx = context(clip([light]), selected: light.id, time: time)
        let set = PointControlHandles(effectID: light.id)
        let handle = try #require(set.handles(ctx).first)
        let moved = set.nudge(handle.id, .right, step: .large, ctx)?.applied(to: ctx.clip)
        let control = moved?.effect(id: light.id)?.control(ControlKind(package: "spotlight", control: "spotCenter"))
        #expect(control?.number.keyframes.count == 2)
        #expect(control?.number.keyframe(at: time)?.value.values == [10, 0])
    }

    @Test func pointsAreKeyTargetsAndReset() throws {
        let light = spotlight(center: [50, 60])
        let ctx = context(clip([light]), selected: light.id)
        let set = PointControlHandles(effectID: light.id)
        let targets = set.keyTargets(ctx)
        #expect(targets.map(\.name) == ["Center"])
        #expect(targets.first?.axes.map(\.name) == ["Center X", "Center Y"])
        let handle = try #require(targets.first).handle
        #expect(set.reset(handle, ctx).flatMap { center(of: $0.applied(to: ctx.clip), light) } == [0, 0])
    }

    @Test func aDrivenPointIsRefused() {
        let light = spotlight()
        var driver = Effect(kind: .audioKeys)
        let controlID = light.control(ControlKind(package: "spotlight", control: "spotCenter"))!.id
        driver.keyframing?.target = .control(effectID: light.id, controlID: controlID)
        let ctx = context(clip([driver, light]), selected: light.id)
        let handle = PointControlHandles(effectID: light.id).handles(ctx).first
        #expect(handle?.isEnabled == false)
        #expect(handle.flatMap { PointControlHandles(effectID: light.id).refusal(for: $0.id, ctx) } != nil)
    }
}
