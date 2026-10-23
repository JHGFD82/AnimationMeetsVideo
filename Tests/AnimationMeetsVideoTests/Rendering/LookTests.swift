import CoreImage
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

/// A look with some of its controls set, by the names they are saved
/// under, as a package's controls have no Swift names.
func look(_ kind: EffectKind, _ settings: [String: [Double]] = [:], choices: [String: String] = [:]) -> Effect {
    var effect = Effect(kind: kind)
    for index in effect.controls.indices {
        let name = effect.controls[index].kind.savedName
        if let values = settings[name] {
            effect.controls[index].number = AnimatedValue(ComponentValue(values: values))
        }
        if let choice = choices[name] { effect.controls[index].choice = choice }
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

    /// Every kernel left in Swift; the packages' are checked in
    /// PackageLookTests.
    @Test func everyKernelCompiles() {
        #expect(LookKernels.compiled.count == LookKernels.split(LookKernels.source).kernels.count)
    }

    @Test func atNoAmountALookDrawsNothing() throws {
        let effect = look(.posterize, ["levels": [2], "amount": [0]])
        #expect(effect.isNoOp)
        let drawn = try draw(effect)
        #expect(close(drawn[2], Tones.pixel(0.8, 0.4, 0.1)))
    }

    @Test func posterizeRoundsEachToneToALevel() throws {
        let drawn = try draw(look(.posterize, ["levels": [2]]))
        #expect(close(drawn[0], Tones.pixel(0, 0, 0)))
        #expect(close(drawn[1], Tones.pixel(1, 1, 1)))
        // Halfway mixes halfway, in the timeline's values.
        let half = try draw(look(.posterize, ["levels": [2], "amount": [50]]))
        let expected = (Tones.pixel(0.3, 0.3, 0.3) + Tones.pixel(0, 0, 0)) / 2
        #expect(close(half[0], SIMD4(expected.x, expected.y, expected.z, 1), tolerance: 0.02))
    }

    @Test func solarizeFoldsTonesAboveTheThreshold() throws {
        let drawn = try draw(look(.solarize, choices: ["solarizeChannels": "each"]))
        // Below the threshold unchanged; 0.75 folds back to 0.25.
        #expect(close(drawn[0], Tones.pixel(0.3, 0.3, 0.3)))
        #expect(close(drawn[1], Tones.pixel(0.25, 0.25, 0.25)))
    }

    @Test func channelMixerSwapsChannels() throws {
        let drawn = try draw(look(.channelMixer, ["mixRed": [0, 0, 1], "mixBlue": [1, 0, 0]]))
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
        let effect = look(.gradientMap, ["shadowColor": [0.1, 0.2, 0.3, 1], "highlightColor": [0.9, 0.8, 0.7, 1]])
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
        let effect = look(.neonEdges, ["edgeWidth": [1], "glow": [0]])
        let drawn = try harness.draw([CompositorHarness.clip(track: 1, effects: [effect], frame: harness.size)])
        let flat = harness.pixel(drawn, x: 2, y: 4)
        let edge = harness.pixel(drawn, x: 8, y: 4)
        #expect(max(flat.x, flat.y, flat.z) < 0.01)
        #expect(max(edge.x, edge.y, edge.z) > 0.5)
    }

    @Test func onlyALookThatMovesIsDrawnAfreshEachFrame() {
        let turning = ClipStack(effects: [look(.hueCycle)])
        let still = ClipStack(effects: [look(.hueCycle, ["hueSpeed": [0]]), look(.posterize)])
        #expect(!turning.animatedRanges.isEmpty)
        #expect(still.animatedRanges.isEmpty)
        // And a still one's render key doesn't carry the time.
        let step = LookStep(look(.posterize), at: CMTime(value: 3, timescale: 1))
        #expect(step?.seconds == 0)
    }
}

@Suite struct NoiseLookTests {
    private func draw(_ effect: Effect, at seconds: Double = 0, picture: SIMD4<Float> = Tones.pixel(0.5, 0.5, 0.5)) throws -> [SIMD4<Float>] {
        var harness = CompositorHarness(size: CGSize(width: 16, height: 8))
        try harness.addSolid(track: 1, picture)
        let clip = CompositorHarness.clip(track: 1, effects: [effect], frame: harness.size)
        return try harness.draw([clip], at: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    private func spread(_ colors: [SIMD4<Float>]) -> Float {
        let reds = colors.map(\.x)
        return (reds.max() ?? 0) - (reds.min() ?? 0)
    }

    @Test func grainIsTheSameEachTimeAFrameIsDrawnAndNewEachFrame() throws {
        let effect = look(.grain)
        let first = try draw(effect, at: 1)
        let again = try draw(effect, at: 1)
        let next = try draw(effect, at: 1 + 1.0 / 24)
        #expect(first == again)
        #expect(first != next)
        #expect(spread(first) > 0.01)
        let otherSeed = try draw(look(.grain, ["seed": [2]]), at: 1)
        #expect(otherSeed != first)
    }

    @Test func generatorsFillWhereNothingWas() throws {
        for kind in [EffectKind.staticNoise, .fractalNoise, .cells, .interference] {
            let drawn = try draw(look(kind, ["noiseScale": [4], "cellSize": [4], "spacing": [3]]), at: 0.5, picture: .zero)
            #expect(drawn.allSatisfy { abs($0.w - 1) < 0.001 }, "\(kind.name) is opaque")
            #expect(drawn.allSatisfy { $0.x >= -0.001 && $0.x <= 1.001 }, "\(kind.name) stays in range")
            #expect(spread(drawn) > 0.05, "\(kind.name) varies")
        }
    }

    @Test func fractalNoiseEvolvesOnlyWithEvolution() throws {
        let still = look(.fractalNoise, ["noiseScale": [4], "evolution": [0]])
        let a = try draw(still, at: 0), b = try draw(still, at: 2)
        #expect(a == b)
        let moving = look(.fractalNoise, ["noiseScale": [4]])
        let c = try draw(moving, at: 0), d = try draw(moving, at: 2)
        #expect(c != d)
    }

    @Test func aBayerDitherKeepsTheAverageTone() throws {
        let drawn = try draw(look(.dither, ["ditherLevels": [2]]), picture: Tones.pixel(0.5, 0.5, 0.5))
        let tones = drawn.map { Tones.tone(Double($0.x)) }
        // Only black and white, half of each.
        #expect(tones.allSatisfy { abs($0) < 0.02 || abs($0 - 1) < 0.02 })
        let mean = tones.reduce(0, +) / Double(tones.count)
        #expect(abs(mean - 0.5) < 0.1)
    }

    @Test func blockGlitchMovesBlocksOnlyAtSomeIntensity() throws {
        var harness = CompositorHarness(size: CGSize(width: 16, height: 8))
        try harness.addPicture(track: 1) { x, _ in SIMD4(Float(x), Float(1 - x), 0.5, 1) }
        func drawn(_ intensity: Double) throws -> [SIMD4<Float>] {
            let effect = look(.blockGlitch, ["intensity": [intensity], "blockSize": [2]])
            return try harness.draw([CompositorHarness.clip(track: 1, effects: [effect], frame: harness.size)], at: CMTime(value: 1, timescale: 1))
        }
        let original = try harness.draw([CompositorHarness.clip(track: 1, frame: harness.size)])
        let none = try drawn(0), all = try drawn(100)
        #expect(none == original)
        #expect(all != original)
    }

    @Test func noiseThatChangesEveryFrameIsDrawnAfreshButDitherIsNot() {
        #expect(!ClipStack(effects: [look(.grain)]).animatedRanges.isEmpty)
        #expect(!ClipStack(effects: [look(.fractalNoise)]).animatedRanges.isEmpty)
        #expect(ClipStack(effects: [look(.dither)]).animatedRanges.isEmpty)
    }
}

@Suite struct LookKernelIdentityTests {
    /// Core Image once took kernels compiled from one source for each
    /// other within a context, drawing one look's cached picture for
    /// another's; each is now compiled on its own.
    @Test func looksDrawnOneAfterAnotherInOneContextEachDrawTheirOwn() throws {
        let size = CGSize(width: 8, height: 4)
        let kinds: [EffectKind] = [.fractalNoise, .cells, .staticNoise, .interference, .neonEdges, .falseColor, .solarize]
        var shared = CompositorHarness(size: size)
        try shared.addPicture(track: 1) { x, y in SIMD4(Float(x), Float(y), 0.5, 1) }
        for kind in kinds {
            var fresh = CompositorHarness(size: size)
            try fresh.addPicture(track: 1) { x, y in SIMD4(Float(x), Float(y), 0.5, 1) }
            let clip = CompositorHarness.clip(track: 1, effects: [Effect(kind: kind)], frame: size)
            let inShared = try shared.draw([clip], at: CMTime(value: 1, timescale: 1))
            let alone = try fresh.draw([clip], at: CMTime(value: 1, timescale: 1))
            #expect(inShared == alone, "\(kind.name)")
        }
    }
}

@Suite struct DistortionLookTests {
    /// A 32 × 32 picture whose every pixel is a different color: red
    /// across, green down.
    private func harness() throws -> CompositorHarness {
        var harness = CompositorHarness(size: CGSize(width: 32, height: 32))
        try harness.addPicture(track: 1) { x, y in SIMD4(Float(x), Float(y), 0.5, 1) }
        return harness
    }

    private func draw(_ effects: [Effect], _ harness: CompositorHarness) throws -> [SIMD4<Float>] {
        try harness.draw([CompositorHarness.clip(track: 1, effects: effects, frame: harness.size)], at: CMTime(value: 1, timescale: 1))
    }

    @Test func everyDistortionKernelCompiles() {
        let warps = ["amvLiquid", "amvTwirl", "amvWave", "amvKaleidoscope", "amvMirrorTile"]
        #expect(warps.allSatisfy { LookKernels.compiled[$0] is CIWarpKernel })
        #expect(LookKernels.compiled["amvDisplace"] != nil && LookKernels.compiled["amvChromaticAberration"] != nil)
    }

    @Test func aTwirlLeavesWhatIsOutsideItsRadiusAlone() throws {
        let h = try harness()
        let original = try draw([], h)
        let twirled = try draw([look(.twirl, ["distortRadius": [8]])], h)
        // A corner is well outside 8 pixels from the middle.
        #expect(close(h.pixel(twirled, x: 1, y: 1), h.pixel(original, x: 1, y: 1)))
        // Inside, it moved.
        #expect(!close(h.pixel(twirled, x: 13, y: 16), h.pixel(original, x: 13, y: 16)))
        let none = try draw([look(.twirl, ["twirlAmount": [0]])], h)
        #expect(none == original)
    }

    @Test func aKaleidoscopeIsMirroredAcrossItsWedges() throws {
        let h = try harness()
        let drawn = try draw([look(.kaleidoscope, ["segments": [4]])], h)
        // Four segments mirror left against right about the middle.
        let left = h.pixel(drawn, x: 10, y: 12), right = h.pixel(drawn, x: 21, y: 12)
        #expect(close(left, right, tolerance: 0.05))
    }

    @Test func fourfoldTilesMirrorAtTheirEdges() throws {
        let h = try harness()
        let drawn = try draw([look(.mirrorTile, ["tileSize": [8]])], h)
        // The tile around the middle runs 12...20; the one to its right is
        // it mirrored, so 18 and 21 read the same place.
        let inside = h.pixel(drawn, x: 18, y: 16), mirrored = h.pixel(drawn, x: 21, y: 16)
        #expect(close(inside, mirrored, tolerance: 0.04))
    }

    @Test func aGrayMapDisplacesNothing() throws {
        var h = try harness()
        try h.addSolid(track: 2, SIMD4(0.5, 0.5, 0.5, 1))
        var effect = look(.displace, ["displacement": [20]])
        effect.input = EffectInput(source: .asset(UUID()))
        var clip = CompositorHarness.clip(track: 1, effects: [effect], frame: h.size)
        let copy = TrackCopy(trackID: 2, range: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1)), strength: 1)
        clip.inputs[effect.id] = .track(copy, base: .identity)
        let drawn = try h.draw([clip], at: CMTime(value: 1, timescale: 1))
        let original = try draw([], h)
        #expect(close(h.pixel(drawn, x: 16, y: 16), h.pixel(original, x: 16, y: 16), tolerance: 0.02))
        // Without a map it does nothing at all.
        #expect(look(.displace).isNoOp)
    }

    @Test func radialAberrationLeavesTheMiddleAlone() throws {
        let h = try harness()
        let original = try draw([], h)
        let drawn = try draw([look(.chromaticAberration, ["aberration": [10]])], h)
        #expect(close(h.pixel(drawn, x: 16, y: 16), h.pixel(original, x: 16, y: 16), tolerance: 0.03))
        // Further out, red comes from further out still (and not past the
        // picture's edge, where there is nothing).
        let edge = h.pixel(drawn, x: 24, y: 16), plain = h.pixel(original, x: 24, y: 16)
        #expect(edge.x > plain.x)
    }

    @Test func movingDistortionsAreDrawnAfresh() {
        #expect(!ClipStack(effects: [look(.liquid)]).animatedRanges.isEmpty)
        #expect(!ClipStack(effects: [look(.wave)]).animatedRanges.isEmpty)
        #expect(ClipStack(effects: [look(.twirl)]).animatedRanges.isEmpty)
        #expect(ClipStack(effects: [look(.kaleidoscope)]).animatedRanges.isEmpty)
    }
}

@Suite struct LookRecipeTests {
    @Test func everyRecipeSavesAndReadsBackAsAPreset() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "amv-recipes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = try #require(UserDefaults(suiteName: "amv-recipes-\(UUID().uuidString)"))
        let written = PresetStore.installRecipes(in: folder, defaults: defaults)
        #expect(written == LookRecipes.all.count)
        let library = PresetStore.load(from: folder)
        #expect(library.problems.isEmpty)
        #expect(library.presets.count == LookRecipes.all.count)
        // Installed once: deleting one doesn't bring it back.
        let first = try #require(library.presets.first)
        try PresetStore.delete(first)
        let again = PresetStore.installRecipes(in: folder, defaults: defaults)
        #expect(again == 0)
    }

    @Test func aRecipesAgainstLinksSurvivePastingOntoAClip() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(added)
        let recipe = try #require(LookRecipes.all.first { $0.name == "Noise Melt" })
        project.paste(recipe.bundle, ontoClip: shape.clipID, in: timelineID, replacingStack: true)
        let clip = try #require(project.clipAndLayer(shape.clipID, in: timelineID)?.clip)
        let noise = try #require(clip.effects.first { $0.kind == .fractalNoise })
        let displace = try #require(clip.effects.first { $0.kind == .displace })
        #expect(displace.against == noise.id)
        #expect(!displace.isNoOp)
    }

    @Test func fastLooksCarryAFlashingNoteAndTheirDefaultsDont() {
        #expect(EditingProject.flashingNote(for: Effect(kind: .staticNoise)) != nil)
        #expect(EditingProject.flashingNote(for: Effect(kind: .blockGlitch)) == nil)
        #expect(EditingProject.flashingNote(for: Effect(kind: .hueCycle)) == nil)
        #expect(EditingProject.flashingNote(for: look(.blockGlitch, ["glitchRate": [8]])) != nil)
        #expect(EditingProject.flashingNote(for: look(.hueCycle, ["hueSpeed": [-4]])) != nil)
    }
}
