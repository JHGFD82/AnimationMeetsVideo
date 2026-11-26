import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A selected shape's gradient in the viewer (see docs/gradients.md,
/// "Where it lies"): a 200 by 100 rectangle in the middle of a 1920 by
/// 1080 frame, from x = 860 to 1060 and y = 490 to 590.
@Suite struct GradientHandlesTests {
    private let frame = CGSize(width: 1920, height: 1080)

    private func shape(_ kind: GradientKind) -> (TimelineClip, Effect) {
        var effect = Effect(kind: .rectangle)
        effect.changeControl(.shapeSize) { $0.number = AnimatedValue(ComponentValue(values: [200, 100])) }
        effect.changeControl(.fill) { $0.setPaint(kind) }
        var clip = TimelineClip(source: .graphic, startOffset: .zero, trimStart: .zero, trimEnd: CMTime(seconds: 5, preferredTimescale: 600))
        clip.effects = [effect]
        return (clip, effect)
    }

    private func context(_ clip: TimelineClip, _ effect: Effect) -> HandleContext {
        HandleContext(clip: clip, sourceTime: .zero, frameSize: frame, pictureRect: CGRect(origin: .zero, size: frame), selectedEffectID: effect.id)
    }

    private func gradient(of clip: TimelineClip, _ effect: Effect) -> PaintGradient? {
        clip.effect(id: effect.id)?.control(.fill)?.gradient(at: .zero)
    }

    @Test func aLinearGradientHasItsEndsAndStopsOnItsLine() {
        let (clip, effect) = shape(.linear)
        let handles = GradientHandles(effectID: effect.id).handles(context(clip, effect))
        let byName = Dictionary(uniqueKeysWithValues: handles.map { ($0.name, $0.place) })
        // Across the middle of the rectangle, left to right.
        #expect(byName["Gradient Start"] == CGPoint(x: 860, y: 540))
        #expect(byName["Gradient End"] == CGPoint(x: 1060, y: 540))
        // The stops a little below the line, clear of the ends.
        let below = CGFloat(GradientHandles.stopOffset)
        #expect(byName["Gradient Stop 1"] == CGPoint(x: 860, y: 540 + below))
        #expect(byName["Gradient Stop 2"] == CGPoint(x: 1060, y: 540 + below))
        #expect(handles.first { $0.name == "Gradient Focal Point" } == nil)
        // The line, and a guide from each stop back to it.
        #expect(GradientHandles(effectID: effect.id).outlines(context(clip, effect)).count == 3)
        // None without a gradient.
        #expect(!GradientHandles.applies(to: Effect(kind: .rectangle)))
    }

    /// A Stroke effect's gradient lies over the outline it strokes, as the
    /// compositor lays it, not over the frame.
    @Test func aStrokeEffectsGradientLiesOverWhatItOutlines() {
        let (rectangle, _) = shape(.linear)
        var stroke = Effect(kind: .stroke)
        stroke.changeControl(.stroke) { $0.enabled = true; $0.setPaint(.linear) }
        var clip = rectangle
        clip.effects.append(stroke)
        let handles = GradientHandles(effectID: stroke.id).handles(context(clip, stroke))
        let byName = Dictionary(uniqueKeysWithValues: handles.map { ($0.name, $0.place) })
        #expect(byName["Gradient Start"] == CGPoint(x: 860, y: 540))
        #expect(byName["Gradient End"] == CGPoint(x: 1060, y: 540))
    }

    @Test func draggingAnEndMovesItsShareOfTheBounds() throws {
        let (clip, effect) = shape(.linear)
        var drag = HandleDrag(handle: .named("gradient.end"), start: CGPoint(x: 1060, y: 540))
        drag.now = CGPoint(x: 1010, y: 565)
        let edit = try #require(GradientHandles(effectID: effect.id).edit(drag, context(clip, effect)))
        var after = clip
        edit.change(&after)
        let moved = try #require(gradient(of: after, effect))
        // 50 of 200 pixels left, 25 of 100 down.
        #expect(abs(moved.end.x - 0.75) < 1e-9 && abs(moved.end.y - 0.75) < 1e-9)
    }

    @Test func aStopMovesAlongTheLineToWhereThePointerIsNearest() throws {
        let (clip, effect) = shape(.linear)
        var drag = HandleDrag(handle: .named("gradient.stop.1"), start: CGPoint(x: 1060, y: 540))
        // Above the line, a quarter of the way along.
        drag.now = CGPoint(x: 910, y: 500)
        let edit = try #require(GradientHandles(effectID: effect.id).edit(drag, context(clip, effect)))
        var after = clip
        edit.change(&after)
        #expect(abs((gradient(of: after, effect)?.stops[1].location ?? 0) - 0.25) < 1e-9)
    }

    @Test func aRadialGradientsFocalPointStaysInsideItsEdge() throws {
        let (clip, effect) = shape(.radial)
        let handles = GradientHandles(effectID: effect.id).handles(context(clip, effect))
        let focal = try #require(handles.first { $0.name == "Gradient Focal Point" })
        #expect(focal.place == CGPoint(x: 960, y: 540))
        var drag = HandleDrag(handle: .named("gradient.focal"), start: focal.place)
        drag.now = CGPoint(x: 2000, y: 540)
        let edit = try #require(GradientHandles(effectID: effect.id).edit(drag, context(clip, effect)))
        var after = clip
        edit.change(&after)
        let moved = try #require(gradient(of: after, effect))
        #expect(hypot(Double(moved.focal.x), Double(moved.focal.y)) < 1)
    }
}
