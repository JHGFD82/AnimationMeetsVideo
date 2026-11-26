import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private let red = [1.0, 0, 0, 1], green = [0.0, 1, 0, 1], black = [0.0, 0, 0, 1], white = [1.0, 1, 1, 1]

/// A gradient's numbers, colors and edits (see docs/gradients.md).
@Suite struct PaintGradientTests {
    @Test func aGradientIsItsNumbers() throws {
        let made = PaintGradient.made(.radial, from: red, to: green)
        let read = try #require(PaintGradient(values: made.values))
        #expect(read == made)
        #expect(made.values.count == PaintGradient.geometryCount + 2 * PaintGradient.numbersPerStop)
        // A color's four numbers aren't a gradient, nor is one stop.
        #expect(PaintGradient(values: red) == nil)
        #expect(PaintGradient(values: Array(made.values.prefix(PaintGradient.geometryCount + PaintGradient.numbersPerStop))) == nil)
    }

    @Test func colorsBlendBetweenStopsAndLeanToTheMidpoint() {
        var gradient = PaintGradient.made(.linear, from: black, to: white)
        #expect(gradient.color(at: 0) == black)
        #expect(gradient.color(at: 1) == white)
        #expect(abs(gradient.color(at: 0.5)[0] - 0.5) < 1e-9)
        // The midpoint moved toward the start: half and half sooner.
        gradient.stops[0].midpoint = 0.25
        #expect(abs(gradient.color(at: 0.25)[0] - 0.5) < 1e-9)
        #expect(gradient.color(at: 0.5)[0] > 0.5)
    }

    @Test func twoStopsAtOnePlaceMakeAHardEdge() {
        var gradient = PaintGradient.made(.linear, from: black, to: white)
        gradient.stops.insert(PaintGradient.Stop(color: black, location: 0.5), at: 1)
        gradient.stops.insert(PaintGradient.Stop(color: white, location: 0.5), at: 2)
        #expect(gradient.color(at: 0.49) == black)
        #expect(gradient.color(at: 0.51) == white)
    }

    @Test func pastItsEndsItHoldsRepeatsOrReflects() {
        #expect(PaintGradient.wrapped(1.25, .hold) == 1)
        #expect(abs(PaintGradient.wrapped(1.25, .repeats) - 0.25) < 1e-9)
        #expect(abs(PaintGradient.wrapped(1.25, .reflect) - 0.75) < 1e-9)
        #expect(abs(PaintGradient.wrapped(-0.25, .reflect) - 0.25) < 1e-9)
        #expect(PaintGradient.wrapped(2, .repeats) == 1)
    }

    @Test func perceptualBlendingKeepsSaturatedMiddlesBright() {
        let gradient = PaintGradient.made(.linear, from: red, to: green)
        let plain = gradient.color(at: 0.5, blend: .values), perceptual = gradient.color(at: 0.5, blend: .perceptual)
        #expect(perceptual[0] + perceptual[1] > plain[0] + plain[1] + 0.3)
        // A color goes through OKLab and back as it was.
        let back = OKLab(rgb: [0.3, 0.6, 0.9, 1]).rgb
        #expect(zip(back, [0.3, 0.6, 0.9]).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func reversingMirrorsStopsAndMidpoints() {
        var gradient = PaintGradient.made(.linear, from: black, to: white)
        gradient.stops[0].midpoint = 0.3
        let reversed = gradient.reversed
        #expect(reversed.stops.map(\.color) == [white, black])
        #expect(reversed.stops.map(\.location) == [0, 1])
        #expect(abs(reversed.stops[0].midpoint - 0.7) < 1e-9)
        // The same colors, mirrored.
        #expect(zip(reversed.color(at: 0.2), gradient.color(at: 0.8)).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test func distributingSpacesTheStopsEvenly() {
        var gradient = PaintGradient.made(.linear, from: black, to: white)
        gradient.stops.insert(PaintGradient.Stop(color: red, location: 0.9), at: 1)
        #expect(gradient.distributed.stops.map(\.location) == [0, 0.5, 1])
    }
}

/// A Fill or Stroke painting a gradient instead of a color.
@Suite struct GradientPaintTests {
    private func fill(_ values: [Double], keyframes: [(Double, [Double])] = []) -> EffectControl {
        var control = EffectControl(kind: .fill)
        control.number = AnimatedValue(
            ComponentValue(values: values),
            keyframes: keyframes.map { Keyframe(time: CMTime(seconds: $0.0, preferredTimescale: 600), value: ComponentValue(values: $0.1)) }
        )
        return control
    }

    @Test func aColorBecomesAGradientFromItAndBack() throws {
        var control = fill([0.2, 0.4, 0.6, 1])
        control.setPaint(.linear)
        #expect(control.paint?.kind == .linear)
        let gradient = try #require(control.gradient(at: .zero))
        #expect(gradient.stops.map(\.color) == [[0.2, 0.4, 0.6, 1], black])
        // Another kind keeps the stops.
        control.setPaint(.radial)
        #expect(control.gradient(at: .zero)?.stops == gradient.stops)
        control.setPaint(nil)
        #expect(control.paint == nil)
        #expect(control.values(at: .zero) == [0.2, 0.4, 0.6, 1])
    }

    @Test func everyKeyframeIsConverted() {
        var control = fill(red, keyframes: [(0, red), (1, green)])
        control.setPaint(.angular)
        let firsts = control.number.keyframes.compactMap { PaintGradient(values: $0.value.values)?.stops.first?.color }
        #expect(firsts == [red, green])
    }

    @Test func aStopAddedOrTakenOutIsAtEveryKeyframe() throws {
        var control = fill(red, keyframes: [(0, red), (1, green)])
        control.setPaint(.linear)
        let index = control.addGradientStop(at: 0.5, time: .zero)
        #expect(index == 1)
        let counts = control.number.keyframes.compactMap { PaintGradient(values: $0.value.values)?.stops.count }
        #expect(counts == [3, 3])
        // Its color is each keyframe's own there.
        let second = try #require(PaintGradient(values: control.number.keyframes[1].value.values))
        #expect(abs(second.stops[1].color[1] - 0.5) < 1e-9)
        control.removeGradientStop(1)
        control.removeGradientStop(0)
        // Never fewer than two.
        #expect(control.number.keyframes.compactMap { PaintGradient(values: $0.value.values)?.stops.count } == [2, 2])
    }

    @Test func aGradientIsntDrivenByAKeyframingMethod() {
        var control = fill(red)
        #expect(control.isDrivable)
        control.setPaint(.linear)
        #expect(!control.isDrivable)
    }
}

/// Shapes drawn with gradients, on the 128 by 72 frame of `DrawingFixture`:
/// a 64 by 36 rectangle in the middle, from x = 32 to 96.
@Suite struct GradientDrawingTests {
    private let second = CMTime(seconds: 1, preferredTimescale: 600)

    private func level(_ composed: ComposedTimeline, x pixel: Double, y row: Double = 36) async throws -> Int {
        try await grayLevel(of: composed, at: second, x: (pixel + 0.5) / 128, y: (row + 0.5) / 72)
    }

    /// A rectangle filled with a gradient of `kind` from black to white,
    /// its end point at `end` of its bounds.
    @discardableResult
    private func box(
        _ kind: GradientKind, end: CGPoint? = nil, repeats: GradientRepeat = .hold, fixture: inout DrawingFixture
    ) throws -> UUID {
        let shape = try fixture.addShape()
        fixture.project.editClip(shape.clipID, in: fixture.timelineID) { clip in
            guard let c = clip.effects[0].controls.firstIndex(where: { $0.kind == .fill }) else { return }
            var made = PaintGradient.made(kind, from: black, to: white)
            if let end { made.end = end }
            clip.effects[0].controls[c].number = AnimatedValue(ComponentValue(values: made.values))
            clip.effects[0].controls[c].paint = PaintStyle(kind: kind, repeats: repeats)
        }
        return shape.clipID
    }

    @Test func aLinearGradientGoesAcrossTheShape() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        try box(.linear, fixture: &fixture)
        let composed = try await fixture.build()
        #expect(try await level(composed, x: 33) < 50)
        #expect(try await level(composed, x: 94) > 200)
        let middle = try await level(composed, x: 64)
        #expect(middle > 90 && middle < 170)
        // Nothing outside the shape.
        #expect(try await level(composed, x: 10) < 10)
    }

    @Test func aRadialGradientSpreadsFromTheMiddle() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let clipID = try box(.radial, fixture: &fixture)
        fixture.project.editClip(clipID, in: fixture.timelineID) { clip in
            guard let c = clip.effects[0].controls.firstIndex(where: { $0.kind == .fill }) else { return }
            // White in the middle, black at its edge, 32 pixels out.
            clip.effects[0].controls[c].editGradientEverywhere { $0.reversed }
        }
        let composed = try await fixture.build()
        #expect(try await level(composed, x: 64) > 200)
        #expect(try await level(composed, x: 40) < 110)
    }

    @Test func repeatingAndReflectingDifferPastTheEnd() async throws {
        // The end half way across: at x = 90.5 it is 1.83 lengths along.
        var repeated = try DrawingFixture()
        defer { repeated.cleanUp() }
        try box(.linear, end: CGPoint(x: 0.5, y: 0.5), repeats: .repeats, fixture: &repeated)
        #expect(try await level(try await repeated.build(), x: 90) > 170)
        var reflected = try DrawingFixture()
        defer { reflected.cleanUp() }
        try box(.linear, end: CGPoint(x: 0.5, y: 0.5), repeats: .reflect, fixture: &reflected)
        #expect(try await level(try await reflected.build(), x: 90) < 80)
    }

    @Test func savingKeepsAGradientAndHowItPaints() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let clipID = try box(.radial, repeats: .reflect, fixture: &fixture)
        fixture.project.editClip(clipID, in: fixture.timelineID) { clip in
            guard let c = clip.effects[0].controls.firstIndex(where: { $0.kind == .fill }) else { return }
            clip.effects[0].controls[c].paint?.blend = .perceptual
            clip.effects[0].controls[c].paint?.space = .frame
            clip.effects[0].controls[c].addGradientStop(at: 0.3, time: .zero)
        }
        let package = fixture.directory.appending(path: "Gradient.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(fixture.project, to: package)
        let loaded = try await ProjectStore.load(from: package)
        let saved = try #require(fixture.project.clipAndLayer(clipID, in: fixture.timelineID)?.clip)
        let read = try #require(loaded.project.clipAndLayer(clipID, in: loaded.project.rootTimelineID)?.clip)
        #expect(read.effects == saved.effects)
        #expect(read.effects[0].control(.fill)?.paint == PaintStyle(kind: .radial, repeats: .reflect, blend: .perceptual, space: .frame))
    }
}

/// Text painted with a block's gradient (see docs/gradients.md, "Where it
/// lies").
@Suite struct TextGradientTests {
    @Test func theBlocksGradientPaintsTheLettersInItsColorOnly() throws {
        var effect = Effect(kind: .text)
        effect.text = TextContent(string: "ab")
        effect.changeControl(.stroke) { $0.enabled = false }
        effect.changeControl(.fill) { fill in
            fill.number = AnimatedValue(ComponentValue(values: [1, 0, 0, 1]))
            fill.setPaint(.linear)
        }
        let whole = try #require(ShapeStep(effect, at: .zero, center: CGPoint(x: 64, y: 36)))
        #expect(whole.paints.count == 1)
        let painted = try #require(whole.paints.first?.gradient)
        // Laid over the whole block.
        #expect(painted.bounds == whole.paints[0].area.boundingBoxOfPath)
        // A run with a color of its own keeps it.
        effect.text?.changeStyle(in: NSRange(location: 1, length: 1)) { style in
            style.fill = AnimatedValue(ComponentValue(values: [0, 0, 1, 1]))
        }
        let styled = try #require(ShapeStep(effect, at: .zero, center: CGPoint(x: 64, y: 36)))
        #expect(styled.paints.count == 2)
        #expect(styled.paints.filter { $0.gradient != nil }.count == 1)
        #expect(styled.paints.contains { $0.gradient == nil && $0.color == [0, 0, 1, 1] })
    }
}
