import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The handles and guides the shipped packages declare in their `viewer`
/// key, dragged as the viewer drags them.
@Suite struct DeclaredHandlesTests {
    private let frame = CGSize(width: 1920, height: 1080)
    private let spotSize = ControlKind(package: "spotlight", control: "spotSize")
    private let spotAngle = ControlKind(package: "spotlight", control: "spotAngle")

    private func clip(_ effects: [Effect]) -> TimelineClip {
        var clip = TimelineClip(source: .graphic, startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 10, timescale: 1))
        clip.effects = effects
        return clip
    }

    private func context(_ clip: TimelineClip, selected: UUID) -> HandleContext {
        HandleContext(clip: clip, sourceTime: .zero, frameSize: frame, pictureRect: CGRect(origin: .zero, size: frame), selectedEffectID: selected)
    }

    private func spotlight(size: [Double] = [600, 400], angle: Double = 0) -> Effect {
        var effect = Effect(kind: EffectKind(package: "spotlight"))
        effect.changeControl(spotSize) { $0.number = AnimatedValue(ComponentValue(values: size)) }
        effect.changeControl(spotAngle) { $0.number = AnimatedValue(ComponentValue(values: [angle])) }
        return effect
    }

    private func close(_ a: CGPoint, _ b: CGPoint, within tolerance: Double = 0.001) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    /// The clip after dragging handle `name` by `delta` on screen.
    private func dragged(_ name: String, by delta: CGVector, _ effect: Effect) throws -> Effect? {
        let ctx = context(clip([effect]), selected: effect.id)
        let set = DeclaredHandles(effectID: effect.id)
        let handle = try #require(set.handles(ctx).first { $0.name == name })
        var drag = HandleDrag(handle: handle.id, start: handle.place)
        drag.move(to: CGPoint(x: handle.place.x + delta.dx, y: handle.place.y + delta.dy), about: nil, holdingWithin: 10)
        return set.edit(drag, ctx)?.applied(to: ctx.clip).effect(id: effect.id)
    }

    @Test func spotlightsSizeAndAngleHaveHandlesBesideItsCenter() {
        let light = spotlight()
        let sets = ViewerHandleSets.active(for: clip([light]), on: TimelineLayer(clips: []), in: .empty, selectedEffectID: light.id)
        #expect(sets.count == 2 && sets[0] is PointControlHandles && sets[1] is DeclaredHandles)
        let handles = DeclaredHandles(effectID: light.id).handles(context(clip([light]), selected: light.id))
        #expect(handles.map(\.name) == ["Width", "Height", "Angle"])
        #expect(handles.allSatisfy { $0.glyph == .diamond })
        #expect(close(handles[0].place, CGPoint(x: 1260, y: 540)))
        #expect(close(handles[1].place, CGPoint(x: 960, y: 740)))
        #expect(close(handles[2].place, CGPoint(x: 1308, y: 540)))
        #expect(handles[0].value == "Size 600 \u{00D7} 400 px")
    }

    @Test func draggingTheEdgesSetsOnePartOfTheSize() throws {
        let light = spotlight()
        let wider = try dragged("Width", by: CGVector(dx: 100, dy: 30), light)
        #expect(wider?.control(spotSize)?.values(at: .zero) == [800, 400])
        let taller = try dragged("Height", by: CGVector(dx: 0, dy: -50), light)
        #expect(taller?.control(spotSize)?.values(at: .zero) == [600, 300])
    }

    @Test func theSizeHandlesFollowATurn() throws {
        let light = spotlight(angle: 90)
        let handles = DeclaredHandles(effectID: light.id).handles(context(clip([light]), selected: light.id))
        // Turned a quarter clockwise, the width runs down the screen.
        #expect(close(handles[0].place, CGPoint(x: 960, y: 840)))
        let wider = try dragged("Width", by: CGVector(dx: 0, dy: 50), light)
        let size = wider?.control(spotSize)?.values(at: .zero) ?? []
        #expect(abs((size.first ?? 0) - 700) < 1e-6 && size.last == 400)
    }

    @Test func theAngleHandleTurnsWithoutJumpingPastAFullTurn() throws {
        let light = spotlight(angle: 0)
        // From straight right to straight down: a quarter clockwise.
        let down = try dragged("Angle", by: CGVector(dx: -348, dy: 348), light)
        #expect(abs((down?.control(spotAngle)?.values(at: .zero).first ?? 0) - 90) < 1e-6)
        // At 350°, a little further clockwise is 360-something, not 0-something.
        let late = spotlight(angle: 350)
        let past = try dragged("Angle", by: CGVector(dx: 0, dy: 120), late)
        let angle = past?.control(spotAngle)?.values(at: .zero).first ?? 0
        #expect(angle > 350 && angle < 380)
    }

    @Test func guidesAreDrawnThroughTheStackBelow() {
        let light = spotlight()
        var below = Effect(kind: .transform)
        below.changeControl(.position) { $0.number = AnimatedValue(ComponentValue(values: [100, 0])) }
        let outlines = DeclaredHandles(effectID: light.id).outlines(context(clip([light, below]), selected: light.id))
        #expect(outlines.count == 2 && outlines.allSatisfy { $0.style == .guide })
        // The ellipse's rightmost point, moved with the picture.
        #expect(close(outlines[0].points[0], CGPoint(x: 1360, y: 540)))
        #expect(outlines[0].isClosed && !outlines[1].isClosed)
    }

    @Test func cornerMasksPointsAreJoined() {
        let mask = Effect(kind: EffectKind(package: "fourPointMask"))
        let outlines = DeclaredHandles(effectID: mask.id).outlines(context(clip([mask]), selected: mask.id))
        #expect(outlines.count == 1 && outlines[0].isClosed)
        #expect(outlines.first.map { zip($0.points, [CGPoint(x: 480, y: 270), CGPoint(x: 1440, y: 270), CGPoint(x: 1440, y: 810), CGPoint(x: 480, y: 810)]).allSatisfy { close($0, $1) } } == true)
        #expect(DeclaredHandles(effectID: mask.id).handles(context(clip([mask]), selected: mask.id)).isEmpty)
    }

    @Test func keysAndResetWork() throws {
        let light = spotlight(size: [900, 400])
        let ctx = context(clip([light]), selected: light.id)
        let set = DeclaredHandles(effectID: light.id)
        let targets = set.keyTargets(ctx)
        #expect(targets.map(\.name) == ["Width", "Height", "Angle"])
        #expect(targets[0].axes.map(\.name) == ["Width, across", "Width, down"])
        let nudged = set.nudge(targets[0].handle, .right, step: .large, ctx)?.applied(to: ctx.clip).effect(id: light.id)
        #expect(nudged?.control(spotSize)?.values(at: .zero) == [920, 400])
        let reset = set.reset(targets[0].handle, ctx)?.applied(to: ctx.clip).effect(id: light.id)
        #expect(reset?.control(spotSize)?.values(at: .zero) == [600, 400])
    }
}
