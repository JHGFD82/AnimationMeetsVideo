import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The tone scale the Color Correction effects work on, restated in
/// double precision for every color space: encoded to linear light (1 is
/// reference white) to ACEScct's log curve, black 0 and white 1.
private enum Scale {
    static let black = 0.0729055341958355, white = 0.5547945

    static func linear(_ e: Double, _ space: ProjectColorSpace) -> Double { TransferCurves.linear(e, space) }
    static func encoded(linear l: Double, _ space: ProjectColorSpace) -> Double { TransferCurves.encoded(linear: l, space) }
    static func lin2log(_ l: Double) -> Double { l <= 0.0078125 ? 10.5402377416545 * l + 0.0729055341958355 : (log2(l) + 9.72) / 17.52 }
    static func log2lin(_ t: Double) -> Double { t <= 0.155251141552511 ? (t - 0.0729055341958355) / 10.5402377416545 : exp2(t * 17.52 - 9.72) }

    static func tone(_ e: Double, _ space: ProjectColorSpace) -> Double { (lin2log(linear(e, space)) - black) / (white - black) }
    static func encoded(tone t: Double, _ space: ProjectColorSpace) -> Double { encoded(linear: log2lin(black + t * (white - black)), space) }

    /// The encoded pixel of three tones, and the tones of a pixel.
    static func pixel(_ r: Double, _ g: Double, _ b: Double, _ space: ProjectColorSpace) -> SIMD4<Float> {
        SIMD4(Float(encoded(tone: r, space)), Float(encoded(tone: g, space)), Float(encoded(tone: b, space)), 1)
    }
    static func tones(_ p: SIMD4<Float>, _ space: ProjectColorSpace) -> SIMD3<Double> {
        SIMD3(tone(Double(p.x), space), tone(Double(p.y), space), tone(Double(p.z), space))
    }
}

@Suite struct CorrectionLookTests {
    private static let spaces: [ProjectColorSpace] = [.rec709, .rec2020PQ]
    /// The kernels that read only their own pixel: each a color kernel,
    /// but Curves, a general one only to read its curves' tables.
    private static let ids = [
        "levels", "curves", "shadowsHighlights", "hueSaturation", "vibrance", "hueRange", "grayPoint", "blackAndWhite", "colorize",
        "sepia", "invert", "threshold", "broadcastSafe",
    ]
    /// Grays, a skin tone, saturated and muted colors, as tones.
    private static let swatches: [SIMD3<Double>] = [
        SIMD3(0, 0, 0), SIMD3(0.3, 0.3, 0.3), SIMD3(0.75, 0.75, 0.75), SIMD3(1, 1, 1),
        SIMD3(0.8, 0.4, 0.1), SIMD3(0.75, 0.55, 0.45), SIMD3(0.2, 0.5, 0.9), SIMD3(0.45, 0.5, 0.4), SIMD3(0.9, 0.1, 0.6),
    ]

    private func kind(_ id: String) throws -> EffectKind { try #require(EffectKind(rawValue: id)) }

    /// `effect` drawn over `pixels` (straight, encoded, opaque) in a
    /// timeline of `space`, each pixel's straight color as drawn.
    private func draw(_ effect: Effect, on pixels: [SIMD4<Float>], in space: ProjectColorSpace) throws -> [SIMD4<Float>] {
        let size = CGSize(width: pixels.count, height: 1)
        let frame = CGRect(origin: .zero, size: size)
        let data = pixels.withUnsafeBytes { Data($0) }
        let picture = CIImage(bitmapData: data, bytesPerRow: pixels.count * 16, size: size, format: .RGBAf, colorSpace: nil)
        let step = try #require(LookStep(effect, at: .zero))
        let drawn = LookRenderer.apply(step, to: picture, over: frame, canvas: frame, frame: frame, scale: 1, space: space)
        var out = [SIMD4<Float>](repeating: .zero, count: pixels.count)
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            .render(drawn, toBitmap: &out, rowBytes: pixels.count * 16, bounds: frame, format: .RGBAf, colorSpace: nil)
        return out
    }

    private func draw(_ effect: Effect, tones: [SIMD3<Double>], in space: ProjectColorSpace) throws -> [SIMD3<Double>] {
        try draw(effect, on: tones.map { Scale.pixel($0.x, $0.y, $0.z, space) }, in: space).map { Scale.tones($0, space) }
    }

    private func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tolerance: Double = 0.01) -> Bool {
        (0..<3).allSatisfy { abs(a[$0] - b[$0]) <= tolerance }
    }

    @Test func theyAreListedTogetherUnderColorCorrection() throws {
        let listed = EffectKind.all.filter { $0.category == .correction }.map(\.rawValue)
        #expect(listed == Self.ids)
        for id in Self.ids {
            let package = try #require(try kind(id).definition.package, "\(id)")
            #expect(package.kernelType == .color || package.readsOnlyItsPixel, "\(id)")
            #expect(PackageKernels.problem(for: package) == nil, "\(id)")
            #expect(!(try kind(id).readsBesidePixels), "\(id)")
        }
    }

    @Test(arguments: spaces) func atNoAmountEachLeavesThePictureAsItIs(space: ProjectColorSpace) throws {
        for id in Self.ids {
            // At 0% it isn't drawn at all; just above, barely at all.
            let off = look(try kind(id), ["amount": [0]])
            #expect(off.isNoOp, "\(id)")
            #expect(LookStep(off, at: .zero) == nil, "\(id)")
            let drawn = try draw(look(try kind(id), ["amount": [0.1]]), tones: Self.swatches, in: space)
            for (a, b) in zip(drawn, Self.swatches) { #expect(near(a, b), "\(id) in \(space)") }
        }
    }

    @Test(arguments: spaces) func atTheirDefaultsTheAdjustmentsChangeNothing(space: ProjectColorSpace) throws {
        for id in ["levels", "shadowsHighlights", "hueSaturation", "vibrance", "hueRange", "grayPoint", "broadcastSafe"] {
            let drawn = try draw(look(try kind(id)), tones: Self.swatches, in: space)
            for (a, b) in zip(drawn, Self.swatches) { #expect(near(a, b), "\(id) in \(space): \(a) for \(b)") }
        }
    }

    @Test(arguments: spaces) func levelsMapsItsBlackAndWhitePoints(space: ProjectColorSpace) throws {
        let input = try draw(look(try kind("levels"), ["inputBlack": [20], "inputWhite": [80]]), tones: [SIMD3(0.2, 0.5, 0.8)], in: space)
        #expect(near(input[0], SIMD3(0, 0.5, 1)))
        let output = try draw(look(try kind("levels"), ["outputBlack": [10], "outputWhite": [90]]), tones: [SIMD3(0, 0.5, 1)], in: space)
        #expect(near(output[0], SIMD3(0.1, 0.5, 0.9)))
        // Gamma 2 takes a quarter to a half: the midtones brighten.
        let gamma = try draw(look(try kind("levels"), ["levelsGamma": [2]]), tones: [SIMD3(0.25, 0, 1)], in: space)
        #expect(near(gamma[0], SIMD3(0.5, 0, 1)))
        // One channel alone.
        let red = try draw(
            look(try kind("levels"), ["inputWhite": [50]], choices: ["levelsChannel": "red"]), tones: [SIMD3(0.4, 0.4, 0.4)], in: space
        )
        #expect(near(red[0], SIMD3(0.8, 0.4, 0.4)))
    }

    @Test(arguments: spaces) func invertingTwiceGivesThePictureBack(space: ProjectColorSpace) throws {
        for channels in ["rgb", "green", "brightness"] {
            let invert = look(try kind("invert"), choices: ["invertChannels": channels])
            let once = try draw(invert, on: Self.swatches.map { Scale.pixel($0.x, $0.y, $0.z, space) }, in: space)
            let twice = try draw(invert, on: once, in: space).map { Scale.tones($0, space) }
            for (a, b) in zip(twice, Self.swatches) { #expect(near(a, b), "\(channels) in \(space)") }
        }
        let once = try draw(look(try kind("invert")), tones: [SIMD3(0.3, 0, 1)], in: space)
        #expect(near(once[0], SIMD3(0.7, 1, 0)))
        // Brightness alone keeps the differences between channels.
        let bright = try draw(look(try kind("invert"), choices: ["invertChannels": "brightness"]), tones: [SIMD3(0.2, 0.3, 0.4)], in: space)
        #expect(abs((bright[0].z - bright[0].x) - 0.2) < 0.01)
    }

    @Test(arguments: spaces) func blackAndWhiteHasNoColorAndWeighsEachHue(space: ProjectColorSpace) throws {
        let drawn = try draw(look(try kind("blackAndWhite")), tones: Self.swatches, in: space)
        for (gray, swatch) in zip(drawn, Self.swatches) {
            #expect(abs(gray.x - gray.y) < 0.002 && abs(gray.y - gray.z) < 0.002, "\(swatch)")
            if swatch.x == swatch.y && swatch.y == swatch.z { #expect(near(gray, swatch)) }
        }
        let hues = try draw(
            look(try kind("blackAndWhite")), tones: [SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 1)], in: space
        )
        #expect(hues.map { ($0.x * 100).rounded() } == [40, 60, 20, 80])
        let brighter = try draw(look(try kind("blackAndWhite"), ["reds": [100]]), tones: [SIMD3(1, 0, 0)], in: space)
        #expect(abs(brighter[0].x - 1) < 0.01)
    }

    @Test(arguments: spaces) func thresholdCutsAtItsLevel(space: ProjectColorSpace) throws {
        let drawn = try draw(look(try kind("threshold")), tones: [SIMD3(0.3, 0.3, 0.3), SIMD3(0.75, 0.75, 0.75), SIMD3(0.9, 0.1, 0.1)], in: space)
        #expect(near(drawn[0], SIMD3(0, 0, 0)))
        #expect(near(drawn[1], SIMD3(1, 1, 1)))
        // A red whose brightness is low is black, but its red alone isn't.
        #expect(near(drawn[2], SIMD3(0, 0, 0)))
        let each = try draw(look(try kind("threshold"), choices: ["thresholdChannels": "each"]), tones: [SIMD3(0.9, 0.1, 0.1)], in: space)
        #expect(near(each[0], SIMD3(1, 0, 0)))
    }

    @Test(arguments: spaces) func hueSaturationDesaturatesAndTurns(space: ProjectColorSpace) throws {
        let gray = try draw(look(try kind("hueSaturation"), ["hueSaturationAmount": [-100]]), tones: Self.swatches, in: space)
        for (a, swatch) in zip(gray, Self.swatches) {
            #expect(abs(a.x - a.y) < 0.002 && abs(a.y - a.z) < 0.002, "\(swatch)")
        }
        // A third of a turn takes red to green, and leaves grays.
        let turned = try draw(look(try kind("hueSaturation"), ["hueShift": [120]]), tones: [SIMD3(0.8, 0.2, 0.2), SIMD3(0.5, 0.5, 0.5)], in: space)
        #expect(near(turned[0], SIMD3(0.2, 0.8, 0.2)))
        #expect(near(turned[1], SIMD3(0.5, 0.5, 0.5)))
        let lighter = try draw(look(try kind("hueSaturation"), ["lightness": [50]]), tones: [SIMD3(0.4, 0.4, 0.4)], in: space)
        #expect(near(lighter[0], SIMD3(0.7, 0.7, 0.7)))
    }

    @Test(arguments: spaces) func vibranceRaisesMutedColorsMoreThanVividOnes(space: ProjectColorSpace) throws {
        let muted = SIMD3(0.45, 0.55, 0.65), vivid = SIMD3(0.1, 0.4, 0.95)
        let drawn = try draw(look(try kind("vibrance"), ["vibranceAmount": [100]]), tones: [muted, vivid, SIMD3(0.5, 0.5, 0.5)], in: space)
        func spread(_ c: SIMD3<Double>) -> Double { c.max() - c.min() }
        let mutedGain = spread(drawn[0]) / spread(muted), vividGain = spread(drawn[1]) / spread(vivid)
        #expect(mutedGain > 1.5)
        #expect(vividGain > 1 && vividGain < mutedGain)
        #expect(near(drawn[2], SIMD3(0.5, 0.5, 0.5)))
        // Skin is spared by Protect Skin Tones.
        let skin = SIMD3(0.75, 0.55, 0.45)
        let protected = try draw(look(try kind("vibrance"), ["vibranceAmount": [100], "protectSkin": [100]]), tones: [skin], in: space)
        let unprotected = try draw(look(try kind("vibrance"), ["vibranceAmount": [100], "protectSkin": [0]]), tones: [skin], in: space)
        #expect(spread(protected[0]) < spread(skin) + 0.05)
        #expect(spread(unprotected[0]) > spread(skin) + 0.1)
    }

    @Test(arguments: spaces) func colorizeAndSepiaToneByBrightness(space: ProjectColorSpace) throws {
        for id in ["colorize", "sepia"] {
            let drawn = try draw(look(try kind(id)), tones: [SIMD3(0, 0, 0), SIMD3(0.5, 0.5, 0.5), SIMD3(1, 1, 1), SIMD3(0.2, 0.5, 0.9)], in: space)
            #expect(near(drawn[0], SIMD3(0, 0, 0)), "\(id)")
            #expect(near(drawn[2], SIMD3(1, 1, 1)), "\(id)")
            // Mid gray takes on a color, keeping about its brightness.
            #expect(drawn[1].max() - drawn[1].min() > 0.1, "\(id)")
            #expect(abs((drawn[1].x + drawn[1].y + drawn[1].z) / 3 - 0.5) < 0.02, "\(id)")
        }
        // Colorize's default hue is a blue; Sepia's a warm brown.
        let blue = try draw(look(try kind("colorize")), tones: [SIMD3(0.5, 0.5, 0.5)], in: space)[0]
        #expect(blue.z > blue.y && blue.y > blue.x)
        let brown = try draw(look(try kind("sepia")), tones: [SIMD3(0.5, 0.5, 0.5)], in: space)[0]
        #expect(brown.x > brown.y && brown.y > brown.z)
    }

    @Test(arguments: spaces) func shadowsLiftOnlyTheDarkTonesInOrder(space: ProjectColorSpace) throws {
        let ramp = (0...40).map { Double($0) / 40 }.map { SIMD3($0, $0, $0) }
        for settings in [["shadows": [100.0]], ["shadows": [-100]], ["highlights": [100]], ["highlights": [-100]]] {
            let drawn = try draw(look(try kind("shadowsHighlights"), settings), tones: ramp, in: space).map(\.x)
            #expect(zip(drawn, drawn.dropFirst()).allSatisfy { $0 < $1 }, "\(settings) keeps the tones in order")
            #expect(abs(drawn[0]) < 0.005 && abs(drawn[40] - 1) < 0.005, "\(settings) keeps black and white")
            // Midway the other end's range is untouched.
            #expect(abs(drawn[20] - 0.5) < 0.005, "\(settings)")
        }
        let lifted = try draw(look(try kind("shadowsHighlights"), ["shadows": [100]]), tones: [SIMD3(0.15, 0.15, 0.15), SIMD3(0.3, 0.1, 0.05)], in: space)
        #expect(lifted[0].x > 0.2)
        // All channels move together, so a color keeps its differences.
        #expect(abs((lifted[1].x - lifted[1].z) - 0.25) < 0.01)
    }

    @Test(arguments: spaces) func aHueRangeChangesOnlyItsHues(space: ProjectColorSpace) throws {
        let swatches = [SIMD3(0.8, 0.2, 0.2), SIMD3(0.2, 0.3, 0.9), SIMD3(0.5, 0.5, 0.5)]
        let drawn = try draw(look(try kind("hueRange"), ["rangeSaturation": [-100]]), tones: swatches, in: space)
        #expect(abs(drawn[0].x - drawn[0].y) < 0.01 && abs(drawn[0].y - drawn[0].z) < 0.01)
        #expect(near(drawn[1], swatches[1]))
        #expect(near(drawn[2], swatches[2]))
        let mask = try draw(look(try kind("hueRange"), choices: ["rangeView": "range"]), tones: swatches, in: space)
        #expect(mask.map { ($0.x * 10).rounded() / 10 } == [1, 0, 0])
    }

    @Test(arguments: spaces) func aGrayPointMakesItsColorGray(space: ProjectColorSpace) throws {
        let cast = Scale.pixel(0.6, 0.5, 0.35, space)
        let effect = look(try kind("grayPoint"), ["neutralColor": [Double(cast.x), Double(cast.y), Double(cast.z), 1]])
        let drawn = try draw(effect, on: [cast, Scale.pixel(0.3, 0.3, 0.3, space)], in: space).map { Scale.tones($0, space) }
        #expect(abs(drawn[0].x - drawn[0].y) < 0.005 && abs(drawn[0].y - drawn[0].z) < 0.005)
        // Everything else is moved the same way: a gray takes the opposite cast.
        #expect(drawn[1].z > drawn[1].x)
    }

    @Test func broadcastSafeKeepsLightAndSaturationWithinItsLimits() throws {
        // Above white in SDR comes down to it; a color past black comes in
        // keeping its hue's order.
        let over = try draw(look(try kind("broadcastSafe")), on: [SIMD4(1.1, 1.1, 1.1, 1), SIMD4(1.2, 0.6, -0.1, 1)], in: .rec709)
        #expect(close(over[0], SIMD4(1, 1, 1, 1), tolerance: 0.002))
        #expect(over[1].z >= -0.0001 && over[1].x <= 1.0001)
        #expect(over[1].x > over[1].y && over[1].y > over[1].z)
        let clipped = try draw(look(try kind("broadcastSafe"), choices: ["safeMethod": "clipping"]), on: [SIMD4(1.2, 0.6, -0.1, 1)], in: .rec709)
        #expect(close(clipped[0], SIMD4(1, 0.6, 0, 1), tolerance: 0.002))

        let limited = try draw(look(try kind("broadcastSafe"), ["saturationLimit": [50]]), on: [SIMD4(0.9, 0.2, 0.1, 1)], in: .rec709)
        let l = (0..<3).map { Scale.linear(Double(limited[0][$0]), .rec709) }
        #expect(abs((l.max()! - l.min()!) / l.max()! - 0.5) < 0.01)

        // In HDR, highlights within Brightest stay; above it come down.
        let highlight = Float(Scale.encoded(linear: 3, .rec2020PQ))
        let kept = try draw(look(try kind("broadcastSafe"), ["ceiling": [493]]), on: [SIMD4(highlight, highlight, highlight, 1)], in: .rec2020PQ)
        #expect(abs(kept[0].x - highlight) < 0.002)
        let capped = try draw(look(try kind("broadcastSafe")), on: [SIMD4(highlight, highlight, highlight, 1)], in: .rec2020PQ)
        #expect(abs(capped[0].x - Float(Scale.encoded(linear: 1, .rec2020PQ))) < 0.002)
    }

    @Test func levelsCarriesHDRHighlightsOnPastWhite() throws {
        // A tone above reference white is not clipped.
        let drawn = try draw(look(try kind("levels"), ["outputBlack": [10]]), tones: [SIMD3(1.2, 1.2, 1.2)], in: .rec2020PQ)
        #expect(abs(drawn[0].x - (0.1 + 1.2 * 0.9)) < 0.01)
    }
}
