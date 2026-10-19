import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The tone scale the looks work on, restated in double precision: Rec.
/// 709 to linear light to ACEScct's log curve, black 0 and white 1.
private enum Tones {
    static let black = 0.0729055341958355, white = 0.5547945

    static func dec709(_ e: Double) -> Double { e < 0.081 ? e / 4.5 : pow((e + 0.099) / 1.099, 1 / 0.45) }
    static func enc709(_ l: Double) -> Double { l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099 }
    static func lin2log(_ l: Double) -> Double { l <= 0.0078125 ? 10.5402377416545 * l + 0.0729055341958355 : (log2(l) + 9.72) / 17.52 }
    static func log2lin(_ t: Double) -> Double { t <= 0.155251141552511 ? (t - 0.0729055341958355) / 10.5402377416545 : exp2(t * 17.52 - 9.72) }

    /// The tone of an encoded value, and the encoded value of a tone.
    static func tone(_ e: Double) -> Double { (lin2log(dec709(e)) - black) / (white - black) }
    static func encoded(_ t: Double) -> Double { enc709(log2lin(black + t * (white - black))) }

    static func pixel(_ r: Double, _ g: Double, _ b: Double) -> SIMD4<Float> {
        SIMD4(Float(encoded(r)), Float(encoded(g)), Float(encoded(b)), 1)
    }
}

/// A look with some of its controls set.
private func look(_ kind: EffectKind, _ settings: [ControlKind: [Double]] = [:], choices: [ControlKind: String] = [:]) -> Effect {
    var effect = Effect(kind: kind)
    for index in effect.controls.indices {
        if let values = settings[effect.controls[index].kind] {
            effect.controls[index].number = AnimatedValue(ComponentValue(values: values))
        }
        if let choice = choices[effect.controls[index].kind] { effect.controls[index].choice = choice }
    }
    return effect
}

@Suite struct LookTests {
    /// The picture: tones 0.3, 0.75 and a color, across.
    private func harness() throws -> CompositorHarness {
        var harness = CompositorHarness(size: CGSize(width: 3, height: 1))
        try harness.addPicture(track: 1) { x, _ in
            switch x {
            case ..<0.34: Tones.pixel(0.3, 0.3, 0.3)
            case ..<0.67: Tones.pixel(0.75, 0.75, 0.75)
            default: Tones.pixel(0.8, 0.4, 0.1)
            }
        }
        return harness
    }

    private func draw(_ effect: Effect, at seconds: Double = 0) throws -> [SIMD4<Float>] {
        let h = try harness()
        let clip = CompositorHarness.clip(track: 1, effects: [effect], frame: h.size)
        return try h.draw([clip], at: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    @Test func everyKernelCompiles() {
        let names = ["amvHueCycle", "amvCosinePalette", "amvGradientMap", "amvSolarize", "amvPosterize",
                     "amvChannelMixer", "amvFalseColor", "amvNeonEdges"]
        #expect(names.allSatisfy { LookKernels.compiled[$0] != nil })
    }

    @Test func atNoAmountALookDrawsNothing() throws {
        let effect = look(.posterize, [.levels: [2], .amount: [0]])
        #expect(effect.isNoOp)
        let drawn = try draw(effect)
        #expect(close(drawn[2], Tones.pixel(0.8, 0.4, 0.1)))
    }

    @Test func posterizeRoundsEachToneToALevel() throws {
        let drawn = try draw(look(.posterize, [.levels: [2]]))
        #expect(close(drawn[0], Tones.pixel(0, 0, 0)))
        #expect(close(drawn[1], Tones.pixel(1, 1, 1)))
        // Halfway mixes halfway, in the timeline's values.
        let half = try draw(look(.posterize, [.levels: [2], .amount: [50]]))
        let expected = (Tones.pixel(0.3, 0.3, 0.3) + Tones.pixel(0, 0, 0)) / 2
        #expect(close(half[0], SIMD4(expected.x, expected.y, expected.z, 1), tolerance: 0.02))
    }

    @Test func solarizeFoldsTonesAboveTheThreshold() throws {
        let drawn = try draw(look(.solarize, choices: [.solarizeChannels: SolarizeChannels.each.rawValue]))
        // Below the threshold unchanged; 0.75 folds back to 0.25.
        #expect(close(drawn[0], Tones.pixel(0.3, 0.3, 0.3)))
        #expect(close(drawn[1], Tones.pixel(0.25, 0.25, 0.25)))
    }

    @Test func channelMixerSwapsChannels() throws {
        let drawn = try draw(look(.channelMixer, [.mixRed: [0, 0, 1], .mixBlue: [1, 0, 0]]))
        #expect(close(drawn[2], Tones.pixel(0.1, 0.4, 0.8)))
    }

    @Test func hueCycleTurnsColorsButNotGrays() throws {
        let quarter = try draw(look(.hueCycle), at: 1)
        // A quarter turn a second, so after one second it has moved.
        #expect(close(quarter[0], Tones.pixel(0.3, 0.3, 0.3)))
        #expect(!close(quarter[2], Tones.pixel(0.8, 0.4, 0.1), tolerance: 0.05))
        // Four seconds is a whole turn, back where it started.
        let whole = try draw(look(.hueCycle), at: 4)
        #expect(close(whole[2], Tones.pixel(0.8, 0.4, 0.1), tolerance: 0.02))
    }

    @Test func aGradientMapTakesTheEndsToTheirColors() throws {
        var harness = CompositorHarness(size: CGSize(width: 2, height: 1))
        try harness.addPicture(track: 1) { x, _ in x < 0.5 ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 1) }
        let effect = look(.gradientMap, [.shadowColor: [0.1, 0.2, 0.3, 1], .highlightColor: [0.9, 0.8, 0.7, 1]])
        let drawn = try harness.draw([CompositorHarness.clip(track: 1, effects: [effect], frame: harness.size)])
        #expect(close(drawn[0], SIMD4(0.1, 0.2, 0.3, 1)))
        #expect(close(drawn[1], SIMD4(0.9, 0.8, 0.7, 1)))
    }

    @Test func aCosinePaletteFollowsItsFormula() throws {
        let drawn = try draw(look(.cosinePalette))
        // Rainbow at tone 0.3: 0.5 + 0.5·cos(2π(0.3 + d)).
        let d = [0.0, 0.33, 0.67]
        let tones = d.map { 0.5 + 0.5 * cos(2 * .pi * (0.3 + $0)) }
        #expect(close(drawn[0], Tones.pixel(tones[0], tones[1], tones[2]), tolerance: 0.015))
    }

    @Test func thermalRunsFromBlackToWhite() throws {
        var harness = CompositorHarness(size: CGSize(width: 2, height: 1))
        try harness.addPicture(track: 1) { x, _ in x < 0.5 ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 1) }
        let drawn = try harness.draw([CompositorHarness.clip(track: 1, effects: [look(.falseColor)], frame: harness.size)])
        #expect(close(drawn[0], SIMD4(0, 0, 0, 1)))
        #expect(close(drawn[1], SIMD4(1, 1, 1, 1)))
    }

    @Test func neonEdgesLightOnlyWhereThePictureChanges() throws {
        var harness = CompositorHarness(size: CGSize(width: 16, height: 8))
        try harness.addPicture(track: 1) { x, _ in x < 0.5 ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 1) }
        let effect = look(.neonEdges, [.edgeWidth: [1], .glow: [0]])
        let drawn = try harness.draw([CompositorHarness.clip(track: 1, effects: [effect], frame: harness.size)])
        let flat = harness.pixel(drawn, x: 2, y: 4)
        let edge = harness.pixel(drawn, x: 8, y: 4)
        #expect(max(flat.x, flat.y, flat.z) < 0.01)
        #expect(max(edge.x, edge.y, edge.z) > 0.5)
    }

    @Test func onlyALookThatMovesIsDrawnAfreshEachFrame() {
        let turning = ClipStack(effects: [look(.hueCycle)])
        let still = ClipStack(effects: [look(.hueCycle, [.hueSpeed: [0]]), look(.posterize)])
        #expect(!turning.animatedRanges.isEmpty)
        #expect(still.animatedRanges.isEmpty)
        // And a still one's render key doesn't carry the time.
        let step = LookStep(look(.posterize), at: CMTime(value: 3, timescale: 1))
        #expect(step?.seconds == 0)
    }
}
