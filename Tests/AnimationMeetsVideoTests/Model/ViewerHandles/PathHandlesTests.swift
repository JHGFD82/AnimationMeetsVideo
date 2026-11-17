import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A path's points and tangents in the viewer, with the arrow
/// (docs/pen-tool.md, "Editing a path").
@Suite struct PathHandlesTests {
    private let frame = CGSize(width: 1920, height: 1080)

    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    private func clip(_ effects: [Effect]) -> TimelineClip {
        var clip = TimelineClip(source: .graphic, startOffset: .zero, trimStart: .zero, trimEnd: seconds(10))
        clip.effects = effects
        return clip
    }

    private func context(_ clip: TimelineClip, selected: UUID?, picked: HandleID? = nil, time: CMTime = .zero) -> HandleContext {
        HandleContext(
            clip: clip, sourceTime: time, frameSize: frame, pictureRect: CGRect(origin: .zero, size: frame),
            selectedEffectID: selected, picked: picked
        )
    }

    /// A Path through three points, the middle one ease.
    private func pathEffect(_ kind: EffectKind = .path) -> Effect {
        var effect = Effect(kind: kind)
        effect.changeControl(.path) {
            $0.setPath(FreePath(vertices: [
                .init(CGPoint(x: -100, y: 0)),
                .init(CGPoint(x: 0, y: -50), in: CGVector(dx: -30, dy: 0), out: CGVector(dx: 60, dy: 0)),
                .init(CGPoint(x: 100, y: 0)),
            ]), at: .zero)
        }
        return effect
    }

    private func moved(by dx: Double) -> Effect {
        var effect = Effect(kind: .transform)
        effect.changeControl(.position) { $0.number = AnimatedValue(ComponentValue(values: [dx, 0])) }
        return effect
    }

    private func path(of clip: TimelineClip?, _ effect: Effect, at time: CMTime = .zero) -> FreePath? {
        clip?.effect(id: effect.id)?.control(.path)?.freePath(at: time)
    }

    @Test func pointsAndTangentsSitWhereTheStackPutsThem() throws {
        let effect = pathEffect()
        let set = PathHandles(effectID: effect.id)
        // A Transform below moves them with the picture; one above doesn't.
        let below = clip([effect, moved(by: 40)])
        let picked = PathHandles.Part.vertex(1).handle
        let handles = set.handles(context(below, selected: effect.id, picked: picked))
        let middle = try #require(handles.first { $0.id == PathHandles.Part.vertex(1).handle })
        #expect(middle.place == CGPoint(x: 960 + 40, y: 540 - 50))
        #expect(middle.glyph == .pickedVertex)
        let out = try #require(handles.first { $0.id == PathHandles.Part.tangent(1, .out).handle })
        #expect(out.place == CGPoint(x: 960 + 40 + 60, y: 540 - 50))
        let above = clip([moved(by: 40), effect])
        let unmoved = set.handles(context(above, selected: effect.id)).first { $0.id == PathHandles.Part.vertex(0).handle }
        #expect(unmoved?.place == CGPoint(x: 960 - 100, y: 540))
        // Nothing picked: no tangents show.
        #expect(set.handles(context(below, selected: effect.id)).allSatisfy { $0.glyph != .tangent })
        // A path's points are from its Position; a mask's from the middle.
        var shifted = pathEffect()
        shifted.changeControl(.shapePosition) { $0.number = AnimatedValue(ComponentValue(values: [10, 20])) }
        let fromPosition = PathHandles(effectID: shifted.id).handles(context(clip([shifted]), selected: shifted.id))
        #expect(fromPosition.first { $0.id == PathHandles.Part.vertex(0).handle }?.place == CGPoint(x: 870, y: 560))
        #expect(ViewerHandleSets.active(
            for: clip([shifted]), on: TimelineLayer(customName: nil, kind: .video, clips: []), in: .empty, selectedEffectID: shifted.id
        ).first is PathHandles)
    }

    @Test func draggingAPointMovesItInWholePixels() throws {
        let effect = pathEffect()
        let original = clip([effect])
        let set = PathHandles(effectID: effect.id)
        var drag = HandleDrag(handle: PathHandles.Part.vertex(0).handle, start: CGPoint(x: 860, y: 540))
        drag.move(to: CGPoint(x: 870.6, y: 545.2), about: nil, holdingWithin: 0)
        let edited = try #require(set.edit(drag, context(original, selected: effect.id))).applied(to: original)
        #expect(path(of: edited, effect)?.vertices[0].point == CGPoint(x: -89, y: 5))
        // Its tangents went with it.
        #expect(path(of: edited, effect)?.vertices[1] == path(of: original, effect)?.vertices[1])
    }

    @Test func anEasePointsTangentsStayInLine() throws {
        let effect = pathEffect()
        let original = clip([effect])
        let set = PathHandles(effectID: effect.id)
        var drag = HandleDrag(handle: PathHandles.Part.tangent(1, .out).handle, start: CGPoint(x: 1020, y: 490))
        drag.move(to: CGPoint(x: 960, y: 490 + 40), about: nil, holdingWithin: 0)
        let edited = try #require(set.edit(drag, context(original, selected: effect.id))).applied(to: original)
        let vertex = try #require(path(of: edited, effect)?.vertices[1])
        #expect(vertex.outTangent == CGVector(dx: 0, dy: 40))
        // In line, at its own length.
        #expect(vertex.inTangent == CGVector(dx: 0, dy: -30))

        // On a broken point it moves alone.
        var broken = pathEffect()
        broken.changeControl(.path) { control in
            var path = control.freePath(at: .zero)
            path.vertices[1].inTangent = CGVector(dx: -30, dy: 30)
            control.setPath(path, at: .zero)
        }
        let cusp = clip([broken])
        let again = try #require(PathHandles(effectID: broken.id).edit(drag, context(cusp, selected: broken.id))).applied(to: cusp)
        #expect(path(of: again, broken)?.vertices[1].inTangent == CGVector(dx: -30, dy: 30))
    }

    @Test func aMovedPointKeyframesOnlyWhereThePathIsAnimated() throws {
        var effect = pathEffect()
        let set = PathHandles(effectID: effect.id)
        var drag = HandleDrag(handle: PathHandles.Part.vertex(2).handle, start: CGPoint(x: 1060, y: 540))
        drag.move(to: CGPoint(x: 1070, y: 540), about: nil, holdingWithin: 0)
        // Not animated: the single value changes.
        let still = clip([effect])
        let plain = try #require(set.edit(drag, context(still, selected: effect.id, time: seconds(2)))).applied(to: still)
        #expect(plain.effect(id: effect.id)?.control(.path)?.isAnimated == false)
        // Animated: a keyframe at the playhead, the others as they were.
        effect.changeControl(.path) { $0.number.setAnimated(true, at: .zero) }
        let animated = clip([effect])
        let keyed = try #require(set.edit(drag, context(animated, selected: effect.id, time: seconds(2)))).applied(to: animated)
        let control = try #require(keyed.effect(id: effect.id)?.control(.path))
        #expect(control.number.keyframes.count == 2)
        #expect(control.freePath(at: .zero).vertices[2].point.x == 100)
        #expect(control.freePath(at: seconds(2)).vertices[2].point.x == 110)
    }

    @Test func aDrivenPathRefuses() {
        let effect = pathEffect()
        var wiggler = Effect(kind: .wiggler)
        let controlID = effect.control(.path)!.id
        wiggler.keyframing?.target = .control(effectID: effect.id, controlID: controlID)
        let driven = clip([wiggler, effect])
        let set = PathHandles(effectID: effect.id)
        let handles = set.handles(context(driven, selected: effect.id))
        #expect(!handles.isEmpty && handles.allSatisfy { !$0.isEnabled && $0.refusal != nil })
        #expect(set.refusal(for: PathHandles.Part.vertex(0).handle, context(driven, selected: effect.id)) != nil)
    }

    @Test func eachPointIsAKeyTargetWithThePensActions() throws {
        let effect = pathEffect(.pathMask)
        let original = clip([effect])
        let targets = PathHandles(effectID: effect.id).keyTargets(context(original, selected: effect.id))
        #expect(targets.map(\.name) == ["Point 1 of 3", "Point 2 of 3", "Point 3 of 3"])
        #expect(targets[1].value.hasPrefix("ease"))
        let names = targets[0].actions.map(\.name)
        #expect(names == ["Add Point After", "Remove Point", "Make Ease", "Close Path"])
        let close = try #require(targets[0].actions.last?.edit(context(original, selected: effect.id)))
        #expect(path(of: close.applied(to: original), effect)?.closed == true)
        // Add Point After the last of an open path goes past its end.
        let add = try #require(targets[2].actions.first?.edit(context(original, selected: effect.id)))
        #expect(path(of: add.applied(to: original), effect)?.vertices.last?.point == CGPoint(x: 200, y: 50))
        // Nudged by the arrows.
        let nudged = try #require(PathHandles(effectID: effect.id).nudge(
            PathHandles.Part.vertex(0).handle, .right, step: .large, context(original, selected: effect.id)
        ))
        #expect(path(of: nudged.applied(to: original), effect)?.vertices[0].point == CGPoint(x: -90, y: 0))
    }
}
