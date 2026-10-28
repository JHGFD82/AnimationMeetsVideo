import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Curves drawn on known tones, and the tone graphs of the effects that
/// have one: their handles against what their kernels draw.
@Suite struct CurvesLookTests {
    private static let spaces: [ProjectColorSpace] = [.rec709, .rec2020PQ]

    /// The tone scale, as `CorrectionLookTests` restates it.
    private enum Scale {
        static let black = 0.0729055341958355, white = 0.5547945
        static func lin2log(_ l: Double) -> Double { l <= 0.0078125 ? 10.5402377416545 * l + black : (log2(l) + 9.72) / 17.52 }
        static func log2lin(_ t: Double) -> Double { t <= 0.155251141552511 ? (t - black) / 10.5402377416545 : exp2(t * 17.52 - 9.72) }
        static func tone(_ e: Double, _ space: ProjectColorSpace) -> Double { (lin2log(TransferCurves.linear(e, space)) - black) / (white - black) }
        static func encoded(tone t: Double, _ space: ProjectColorSpace) -> Double {
            TransferCurves.encoded(linear: log2lin(black + t * (white - black)), space)
        }
    }

    private var curves: EffectKind { get throws { try #require(EffectKind(rawValue: "curves")) } }

    private func points(_ points: [(Double, Double)]) -> [Double] {
        ToneCurve(points: points.map { ToneCurve.Point(x: $0.0, y: $0.1) }).values
    }

    /// `effect` drawn over `tones` in a timeline of `space`, as tones.
    private func draw(_ effect: Effect, tones: [SIMD3<Double>], in space: ProjectColorSpace) throws -> [SIMD3<Double>] {
        let pixels: [Float] = tones.flatMap { t -> [Float] in [t.x, t.y, t.z].map { Float(Scale.encoded(tone: $0, space)) } + [1] }
        let frame = CGRect(x: 0, y: 0, width: tones.count, height: 1)
        let step = try #require(LookStep(effect, at: .zero))
        let drawn = LookRenderer.apply(
            step, to: FloatBitmap.image(pixels, width: tones.count, height: 1), over: frame, canvas: frame, frame: frame, scale: 1, space: space
        )
        let read = FloatBitmap.read(drawn, width: tones.count, height: 1)
        return tones.indices.map { i in SIMD3((0..<3).map { Scale.tone(Double(read[i * 4 + $0]), space) }) }
    }

    private func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tolerance: Double = 0.01) -> Bool {
        (0..<3).allSatisfy { abs(a[$0] - b[$0]) <= tolerance }
    }

    @Test func itIsAColorCorrectionReadingOnlyItsPixel() throws {
        let kind = try curves
        #expect(kind.category == .correction)
        #expect(EffectKind.all.filter { $0.category == .correction }.map(\.rawValue).prefix(2) == ["levels", "curves"])
        let package = try #require(kind.definition.package)
        #expect(package.readsOnlyItsPixel && !kind.readsBesidePixels)
        // Reach 0 with filters after (the blurs) still reads beside.
        #expect(try #require(EffectKind(rawValue: "gaussianBlur")).readsBesidePixels)
        #expect(PackageKernels.problem(for: package) == nil)
        #expect(kind.toneGraph?.curves.count == 4)
    }

    @Test(arguments: spaces) func atTheirDefaultsTheCurvesChangeNothing(space: ProjectColorSpace) throws {
        let swatches = [SIMD3(0.0, 0, 0), SIMD3(0.3, 0.3, 0.3), SIMD3(1, 1, 1), SIMD3(0.8, 0.4, 0.1), SIMD3(0.2, 0.5, 0.9)]
        let drawn = try draw(Effect(kind: try curves), tones: swatches, in: space)
        for (a, b) in zip(drawn, swatches) { #expect(near(a, b, 0.002), "\(a) for \(b) in \(space)") }
    }

    @Test(arguments: spaces) func theRGBCurveMapsEveryChannel(space: ProjectColorSpace) throws {
        let lifted = look(try curves, ["masterCurve": points([(0, 0), (0.5, 0.7), (1, 1)])])
        let drawn = try draw(lifted, tones: [SIMD3(0.5, 0, 1), SIMD3(0.25, 0.75, 0.5)], in: space)
        #expect(near(drawn[0], SIMD3(0.7, 0, 1)))
        let curve = ToneCurve(values: points([(0, 0), (0.5, 0.7), (1, 1)]))
        #expect(near(drawn[1], SIMD3(curve.value(at: 0.25), curve.value(at: 0.75), 0.7)))
    }

    @Test(arguments: spaces) func eachChannelsCurveComesAfterTheRGBOne(space: ProjectColorSpace) throws {
        // Red alone, turned end for end.
        let inverted = look(try curves, ["redCurve": points([(0, 1), (1, 0)])])
        #expect(near(try draw(inverted, tones: [SIMD3(0.2, 0.2, 0.2)], in: space)[0], SIMD3(0.8, 0.2, 0.2)))
        // The RGB curve halves every tone, then red's doubles them back.
        let both = look(try curves, ["masterCurve": points([(0, 0), (1, 0.5)]), "redCurve": points([(0, 0), (0.5, 1)])])
        #expect(near(try draw(both, tones: [SIMD3(0.6, 0.6, 0.6)], in: space)[0], SIMD3(0.6, 0.3, 0.3)))
    }

    @Test(arguments: spaces) func hdrTonesCarryOnPastWhite(space: ProjectColorSpace) throws {
        // Rec. 709's code values run past 1 for these in a float picture.
        let identity = try draw(Effect(kind: try curves), tones: [SIMD3(1.4, 1.4, 1.4)], in: space)
        #expect(near(identity[0], SIMD3(repeating: 1.4), 0.005))
        let shape = points([(0, 0), (0.5, 0.75), (1, 1)])
        let bent = try draw(look(try curves, ["masterCurve": shape]), tones: [SIMD3(1.4, 1.4, 1.4)], in: space)
        #expect(abs(bent[0].x - ToneCurve(values: shape).value(at: 1.4)) < 0.01)
    }

    @Test func itDrawsOnlyOverItsPicture() throws {
        let effect = look(try curves, ["masterCurve": points([(0, 0.5), (1, 1)])])
        let step = try #require(LookStep(effect, at: .zero))
        let canvas = CGRect(x: -10, y: -10, width: 40, height: 40)
        let region = CGRect(x: 0, y: 0, width: 4, height: 4)
        let picture = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: region)
        let drawn = LookRenderer.apply(step, to: picture, over: region, canvas: canvas, frame: region, scale: 1, space: .rec709)
        #expect(drawn.extent == region)
    }

    // MARK: Graphs

    private func kind(_ id: String) throws -> EffectKind { try #require(EffectKind(rawValue: id)) }

    private func handle(_ name: String, of kind: EffectKind) throws -> EffectPackage.Graph.Handle {
        try #require(kind.toneGraph?.handles.first { $0.name == name })
    }

    /// The measured tone at `x`, from the response's samples.
    private func response(_ samples: [SIMD3<Double>], at x: Double) -> Double {
        let at = x * Double(samples.count - 1)
        let low = Int(at.rounded(.down)).clamped(between: 0, and: samples.count - 2)
        let fraction = at - Double(low)
        return samples[low].y + (samples[low + 1].y - samples[low].y) * fraction
    }

    @Test func levelsHandlesSitOnWhatItDrawsAndSetItsControls() throws {
        let levels = try kind("levels")
        let package = try #require(levels.definition.package)
        var effect = Effect(kind: levels)
        let black = try handle("Black", of: levels), white = try handle("White", of: levels), gamma = try handle("Gamma", of: levels)
        #expect(black.place(in: effect, of: package, at: .zero) == (0, 0))
        #expect(white.place(in: effect, of: package, at: .zero) == (1, 1))
        #expect(gamma.place(in: effect, of: package, at: .zero) == (0.5, 0.5))
        #expect(black.movesAcross && black.movesUp && gamma.movesAcross && !gamma.movesUp)

        // Each handle is where the kernel puts its tone: black and white
        // while the line between them is straight, gamma once it bends
        // (it rises steeply from black then, too steeply to read between
        // the grays measured).
        func onTheLine(_ handles: [EffectPackage.Graph.Handle]) throws {
            let measured = try #require(ToneResponse.measure(effect, at: .zero))
            for handle in handles {
                let place = handle.place(in: effect, of: package, at: .zero)
                #expect(abs(response(measured, at: place.x) - place.y) < 0.01, "\(handle.name) at \(place)")
            }
        }
        effect = black.dragging(effect, of: package, to: 0.2, 0.1, at: .zero)
        effect = white.dragging(effect, of: package, to: 0.8, 0.9, at: .zero)
        try onTheLine([black, white, gamma])
        // A quarter of the way between black and white is gamma 2.
        effect = gamma.dragging(effect, of: package, to: 0.35, 0.7, at: .zero)
        try onTheLine([gamma, white])
        let values = { (name: String) in effect.controls.first { $0.kind.savedName == name }?.values(at: .zero).first ?? .nan }
        #expect(abs(values("inputBlack") - 20) < 1e-9 && abs(values("outputBlack") - 10) < 1e-9)
        #expect(abs(values("inputWhite") - 80) < 1e-9 && abs(values("outputWhite") - 90) < 1e-9)
        #expect(abs(values("levelsGamma") - 2) < 1e-9)
    }

    @Test func highsAndLowsHandlesFollowTheirBumps() throws {
        let kind = try kind("shadowsHighlights")
        let package = try #require(kind.definition.package)
        var effect = Effect(kind: kind)
        let shadows = try handle("Shadows", of: kind), highlights = try handle("Highlights", of: kind)
        // Lifted and deepened, recovered and brightened, each within ±100%.
        for (handle, to) in [(shadows, (0.12, 0.18)), (shadows, (0.1, 0.07)), (highlights, (0.85, 0.8)), (highlights, (0.9, 0.93))] {
            effect = handle.dragging(effect, of: package, to: to.0, to.1, at: .zero)
            let place = handle.place(in: effect, of: package, at: .zero)
            #expect(abs(place.x - to.0) < 1e-9 && abs(place.y - to.1) < 1e-9, "\(handle.name) dragged to \(to)")
            let measured = try #require(ToneResponse.measure(effect, at: .zero))
            #expect(abs(response(measured, at: place.x) - place.y) < 0.01, "\(handle.name) on what it draws")
        }
    }

    @Test func thresholdAndSolarizeHandlesMoveTheirLevels() throws {
        for (id, name, control) in [("threshold", "Level", "thresholdLevel"), ("solarize", "Threshold", "solarizeLevel")] {
            let kind = try kind(id)
            let package = try #require(kind.definition.package)
            let moved = try handle(name, of: kind).dragging(Effect(kind: kind), of: package, to: 0.3, 0.9, at: .zero)
            #expect(moved.controls.first { $0.kind.savedName == control }?.values(at: .zero) == [30], "\(id)")
        }
    }

    @Test func aResponseIsTheGraysForAnEffectThatDrawsNothing() throws {
        var levels = Effect(kind: try kind("levels"))
        levels.enabled = false
        let grays = try #require(ToneResponse.measure(levels, at: .zero))
        #expect(grays.count == ToneResponse.count)
        #expect(grays.allSatisfy { $0.x == $0.y && $0.y == $0.z })
        #expect(ToneResponse.measure(Effect(kind: .transform), at: .zero) == nil)
        // Measured, a default Levels is the grays too.
        let measured = try #require(ToneResponse.measure(Effect(kind: try kind("levels")), at: .zero))
        for (a, b) in zip(measured, grays) { #expect(abs(a.x - b.x) < 0.003) }
    }
}
