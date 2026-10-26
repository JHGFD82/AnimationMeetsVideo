import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The Blur & Sharpen packages that ship (docs/effects-blur.md), each
/// drawn through the compositor on a small known picture.
@Suite struct BlurLookTests {
    private static let side = 32

    /// A frame `side` pixels square in which `color(x, y)`, by pixel from
    /// the top left, gives each pixel's straight RGBA.
    private func harness(_ color: @escaping (Int, Int) -> SIMD4<Float>) throws -> CompositorHarness {
        var harness = CompositorHarness(size: CGSize(width: Self.side, height: Self.side))
        try harness.addPicture(track: 1) { x, y in
            color(Int(x * Double(Self.side)), Int(y * Double(Self.side)))
        }
        return harness
    }

    private func draw(_ effect: Effect, on harness: CompositorHarness) throws -> [SIMD4<Float>] {
        try harness.draw([CompositorHarness.clip(track: 1, effects: [effect], frame: harness.size)])
    }

    private func gray(_ v: Float) -> SIMD4<Float> { SIMD4(v, v, v, 1) }

    /// White in a 2 × 2 square at (`x`, `y`), on black.
    private func dot(atX dx: Int = 16, y dy: Int = 16) throws -> CompositorHarness {
        try harness { x, y in (dx - 1...dx).contains(x) && (dy - 1...dy).contains(y) ? SIMD4(1, 1, 1, 1) : SIMD4(0, 0, 0, 1) }
    }

    private func at(_ pixels: [SIMD4<Float>], _ x: Int, _ y: Int) -> SIMD4<Float> { pixels[y * Self.side + x] }

    private func same(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Bool {
        zip(a, b).allSatisfy { close($0, $1, tolerance: 0.004) }
    }

    @Test func theyAreInTheBlurCategoryAndCompile() throws {
        let kinds = EffectKind.all.filter { $0.category == .blur }.map(\.rawValue)
        #expect(kinds == ["gaussianBlur", "directionalBlur", "zoomBlur", "spinBlur", "lensBlur", "tiltShift", "surfaceBlur", "sharpen", "unsharpMask"])
        for kind in kinds {
            let package = try #require(EffectKind(package: kind).definition.package)
            #expect(PackageKernels.problem(for: package) == nil, "\(kind)")
            #expect(package.dependsOnPixelSize, "\(kind)")
            #expect(EffectKind(package: kind).readsBesidePixels, "\(kind)")
            #expect(package.linear, "\(kind)")
        }
    }

    @Test func atNoneEachLeavesThePictureAsItIs() throws {
        let h = try dot(atX: 12, y: 20)
        let original = try h.draw([CompositorHarness.clip(track: 1, frame: h.size)])
        let off: [(EffectKind, [String: [Double]])] = [
            (EffectKind(package: "gaussianBlur"), ["blurRadius": [0]]),
            (EffectKind(package: "directionalBlur"), ["blurLength": [0]]),
            (EffectKind(package: "zoomBlur"), ["zoomAmount": [0]]),
            (EffectKind(package: "spinBlur"), ["spinAngle": [0]]),
            (EffectKind(package: "lensBlur"), ["blurRadius": [0]]),
            (EffectKind(package: "tiltShift"), ["blurRadius": [0]]),
            (EffectKind(package: "surfaceBlur"), ["surfaceRadius": [0]]),
            (EffectKind(package: "sharpen"), ["sharpness": [0]]),
            (EffectKind(package: "unsharpMask"), ["unsharpAmount": [0]]),
        ]
        for (kind, settings) in off {
            #expect(same(try draw(look(kind, settings), on: h), original), "\(kind.rawValue)")
        }
    }

    @Test func gaussianBlurSpreadsADotEvenly() throws {
        let drawn = try draw(look(EffectKind(package: "gaussianBlur"), ["blurRadius": [3]]), on: try dot())
        // The dot dims and spreads the same way in every direction.
        #expect(at(drawn, 15, 15).x < 0.5)
        let right = at(drawn, 20, 15).x, below = at(drawn, 15, 20).x
        #expect(right > 0.01)
        #expect(abs(right - below) < 0.01)
        #expect(at(drawn, 31, 0).x < 0.001)
    }

    @Test func blursRepeatTheFrameEdgesOrFadeThem() throws {
        let h = try harness { _, _ in SIMD4(1, 1, 1, 1) }
        let small: [String: [String: [Double]]] = [
            "gaussianBlur": ["blurRadius": [2]], "directionalBlur": ["blurLength": [4]], "lensBlur": ["blurRadius": [3]],
            "zoomBlur": ["zoomAmount": [-50]], "spinBlur": ["spinAngle": [60]],
        ]
        for (kind, settings) in small {
            let repeated = try draw(look(EffectKind(package: kind), settings), on: h)
            #expect(close(at(repeated, 0, 0), SIMD4(1, 1, 1, 1)), "\(kind)")
            // Faded, the black under the frame shows at its corners.
            let faded = try draw(look(EffectKind(package: kind), settings, choices: ["blurEdges": "transparent"]), on: h)
            #expect(at(faded, 0, 0).x < 0.9, "\(kind)")
            // The middle stays as it was.
            #expect(close(at(faded, 16, 16), SIMD4(1, 1, 1, 1)), "\(kind)")
        }
    }

    @Test func directionalBlurSpreadsAlongItsAngleOnly() throws {
        let kind = EffectKind(package: "directionalBlur")
        let across = try draw(look(kind, ["blurLength": [8]]), on: try dot())
        #expect(at(across, 20, 15).x > 0.03)
        #expect(at(across, 15, 20).x < 0.002)
        let down = try draw(look(kind, ["blurLength": [8], "blurAngle": [90]]), on: try dot())
        #expect(at(down, 15, 20).x > 0.03)
        #expect(at(down, 20, 15).x < 0.002)
    }

    @Test func zoomBlurStreaksAlongLinesFromTheCenter() throws {
        let drawn = try draw(look(EffectKind(package: "zoomBlur"), ["zoomAmount": [50]]), on: try dot(atX: 25))
        // Outward of the dot, on its line to the middle, it streaks.
        #expect(at(drawn, 29, 15).x > 0.03)
        // Beside it, across the line, nothing.
        #expect(at(drawn, 24, 20).x < 0.002)
        // The middle doesn't move.
        #expect(at(drawn, 16, 16).x < 0.002)
    }

    @Test func spinBlurStreaksAroundTheCenter() throws {
        // The dot 9 pixels right of the middle, turned through 90°.
        let drawn = try draw(look(EffectKind(package: "spinBlur"), ["spinAngle": [90]]), on: try dot(atX: 25))
        // Along its circle, both ways.
        let up = at(drawn, 23, 11).x, down = at(drawn, 23, 20).x
        #expect(up > 0.02)
        #expect(down > 0.02)
        // Further out on its line from the middle, nothing.
        #expect(at(drawn, 30, 15).x < 0.002)
    }

    @Test func lensBlurSpreadsADotIntoADisc() throws {
        let drawn = try draw(look(EffectKind(package: "lensBlur"), ["blurRadius": [5]]), on: try dot())
        #expect(at(drawn, 15, 15).x < 0.5)
        #expect(at(drawn, 18, 15).x > 0.01)
        // A disc has an edge, as a Gaussian hasn't.
        #expect(at(drawn, 26, 15).x < 0.002)
    }

    @Test func tiltShiftKeepsItsBandSharpAndBlursAway() throws {
        // Stripes a pixel wide.
        let h = try harness { x, _ in x % 2 == 0 ? SIMD4(1, 1, 1, 1) : SIMD4(0, 0, 0, 1) }
        let kind = EffectKind(package: "tiltShift")
        let drawn = try draw(look(kind, ["focusSize": [2], "focusFalloff": [4], "blurRadius": [3]]), on: h)
        func contrast(_ y: Int) -> Float { abs(at(drawn, 10, y).x - at(drawn, 11, y).x) }
        #expect(contrast(16) > 0.9)
        #expect(contrast(1) < 0.1)
        #expect(contrast(30) < 0.1)
        // Turned upright, the band runs down the frame.
        let turned = try draw(look(kind, ["focusSize": [2], "focusFalloff": [4], "blurRadius": [3], "focusAngle": [90]]), on: h)
        #expect(abs(at(turned, 16, 2).x - at(turned, 15, 2).x) > 0.9)
        #expect(abs(at(turned, 2, 16).x - at(turned, 3, 16).x) < 0.1)
    }

    @Test func surfaceBlurSmoothsNoiseAndKeepsEdges() throws {
        // Dark and light halves, each with noise.
        func noise(_ x: Int, _ y: Int) -> Float { Float((x * 7919 + y * 104729) % 13) / 13 * 0.06 - 0.03 }
        let h = try harness { x, y in self.gray((x < 16 ? 0.25 : 0.75) + noise(x, y)) }
        let drawn = try draw(look(EffectKind(package: "surfaceBlur"), ["surfaceRadius": [4]]), on: h)
        func spread(_ pixels: [SIMD4<Float>]) -> Float {
            let values = (4..<12).flatMap { y in (2..<12).map { x in at(pixels, x, y).x } }
            return values.max()! - values.min()!
        }
        let before = try h.draw([CompositorHarness.clip(track: 1, frame: h.size)])
        #expect(spread(drawn) < spread(before) / 2)
        // The edge between the halves stays sharp.
        #expect(abs(at(drawn, 15, 10).x - 0.25) < 0.05)
        #expect(abs(at(drawn, 16, 10).x - 0.75) < 0.05)
    }

    @Test func sharpeningRaisesContrastAtAnEdgeOnly() throws {
        let h = try harness { x, _ in self.gray(x < 16 ? 0.3 : 0.7) }
        for (kind, settings) in [("sharpen", ["sharpness": [100.0]]), ("unsharpMask", ["unsharpAmount": [100.0]])] {
            let drawn = try draw(look(EffectKind(package: kind), settings), on: h)
            #expect(at(drawn, 15, 16).x < 0.29, "\(kind)")
            #expect(at(drawn, 16, 16).x > 0.71, "\(kind)")
            // Away from the edge, and at the frame's edges, as it was.
            #expect(abs(at(drawn, 4, 16).x - 0.3) < 0.005, "\(kind)")
            #expect(abs(at(drawn, 0, 0).x - 0.3) < 0.005, "\(kind)")
            #expect(abs(at(drawn, 31, 31).x - 0.7) < 0.005, "\(kind)")
        }
    }

    // MARK: HDR

    private static let spaces: [ProjectColorSpace] = [.rec709, .rec2020PQ, .rec2020HLG]

    /// A picture given in linear light (1 is reference white), encoded as
    /// a timeline of `space` holds it.
    private func harness(in space: ProjectColorSpace, light: @escaping (Int, Int) -> Double) throws -> CompositorHarness {
        try harness { x, y in self.gray(Float(TransferCurves.encoded(linear: light(x, y), space))) }
    }

    /// `pixels` as linear light, red's.
    private func light(_ pixels: [SIMD4<Float>], in space: ProjectColorSpace) -> [Double] {
        pixels.map { TransferCurves.linear(Double($0.x), space) }
    }

    /// Reference white in a 4 × 4 square right of the middle, on a dim
    /// field, so Zoom and Spin have somewhere to streak it.
    private func square(_ x: Int, _ y: Int, bright: Double = 1) -> Double {
        (21...24).contains(x) && (14...17).contains(y) ? bright : 0.02
    }

    /// Each one averages light, not the picture as it is encoded: the same
    /// light blurs to the same light in Rec. 709, PQ and HLG. Averaging PQ
    /// or HLG's values instead darkens a highlight far more than Rec.
    /// 709's do, so the three would disagree.
    @Test func eachSpreadsLightTheSameInSDRAndHDR() throws {
        let effects: [(String, [String: [Double]])] = [
            ("gaussianBlur", ["blurRadius": [3]]), ("directionalBlur", ["blurLength": [4]]), ("zoomBlur", ["zoomAmount": [40]]),
            ("spinBlur", ["spinAngle": [30]]), ("lensBlur", ["blurRadius": [3]]), ("tiltShift", ["focusSize": [0], "focusFalloff": [0], "blurRadius": [3]]),
            ("surfaceBlur", ["surfaceRadius": [4], "surfaceThreshold": [100]]), ("sharpen", ["sharpness": [100]]),
            ("unsharpMask", ["unsharpAmount": [100]]),
        ]
        for (kind, settings) in effects {
            let effect = look(EffectKind(package: kind), settings)
            var drawn: [ProjectColorSpace: [Double]] = [:]
            var original: [Double] = []
            for space in Self.spaces {
                let h = try harness(in: space) { self.square($0, $1) }
                let clip = CompositorHarness.clip(track: 1, effects: [effect], frame: h.size, colorSpace: space)
                drawn[space] = light(try h.draw([clip], colorSpace: space), in: space)
                if space == .rec709 {
                    original = light(try h.draw([CompositorHarness.clip(track: 1, frame: h.size)]), in: space)
                }
            }
            let sdr = try #require(drawn[.rec709])
            // It did something.
            #expect((zip(sdr, original).map { abs($0 - $1) }.max() ?? 0) > 0.1, "\(kind)")
            for space in [ProjectColorSpace.rec2020PQ, .rec2020HLG] {
                let worst = zip(sdr, try #require(drawn[space])).map { abs($0 - $1) }.max() ?? 0
                #expect(worst < 0.01, "\(kind) in \(space) differs from Rec. 709 by \(worst)")
            }
        }
    }

    /// A 1000-nit highlight on a PQ timeline spreads into a glow that keeps
    /// its light and stays brighter than SDR's white, rather than fading
    /// to a few nits.
    @Test func aBlurredHDRHighlightKeepsItsLight() throws {
        let nits1000 = 1000.0 / 203
        let h = try harness(in: .rec2020PQ) { self.square($0, $1, bright: nits1000) }
        let plain = CompositorHarness.clip(track: 1, frame: h.size, colorSpace: .rec2020PQ)
        let before = light(try h.draw([plain], colorSpace: .rec2020PQ), in: .rec2020PQ)
        for (kind, settings) in [
            // Short enough to keep the light inside the frame.
            ("gaussianBlur", ["blurRadius": [3.0]]), ("directionalBlur", ["blurLength": [4.0]]), ("lensBlur", ["blurRadius": [3.0]]),
        ] {
            let effect = look(EffectKind(package: kind), settings)
            let clip = CompositorHarness.clip(track: 1, effects: [effect], frame: h.size, colorSpace: .rec2020PQ)
            let pixels = try h.draw([clip], colorSpace: .rec2020PQ)
            let after = light(pixels, in: .rec2020PQ)
            let kept = after.reduce(0, +) / before.reduce(0, +)
            #expect(abs(kept - 1) < 0.03, "\(kind) kept \(kept) of the light")
            #expect((after.max() ?? 0) > 1, "\(kind)")
        }
    }
}
