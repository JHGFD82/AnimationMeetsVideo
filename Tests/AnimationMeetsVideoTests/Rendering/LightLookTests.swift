import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The looks of the Light category (docs/effects-light.md), each drawn
/// through the compositor on a known picture: a dark field with a white
/// dot.
@Suite struct LightLookTests {
    private typealias Color = CompositorHarness.Color

    private static let size = CGSize(width: 64, height: 36)
    private static let kinds = ["glow", "bloom", "halation", "lightRays", "lensFlare", "lightLeak", "spotlight", "vignette"]

    /// A gray field `field` bright with a white dot `radius` pixels across
    /// at `dot`, in pixels from the top left, or none.
    private func harness(dot: CGPoint? = CGPoint(x: 32, y: 18), radius: Double = 2, field: Float = 0.1) throws -> CompositorHarness {
        var harness = CompositorHarness(size: Self.size)
        try harness.addPicture(track: 1) { x, y in
            if let dot {
                let dx = x * Self.size.width - dot.x, dy = y * Self.size.height - dot.y
                if dx * dx + dy * dy <= radius * radius { return Color(1, 1, 1, 1) }
            }
            return Color(field, field, field, 1)
        }
        return harness
    }

    private func draw(_ effect: Effect, on harness: CompositorHarness, at seconds: Double = 0) throws -> [Color] {
        let clip = CompositorHarness.clip(track: 1, effects: [effect], frame: harness.size)
        return try harness.draw([clip], at: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// The pixel `x` across and `y` down.
    private func pixel(_ colors: [Color], x: Int, y: Int) -> Color {
        colors[y * Int(Self.size.width) + x]
    }

    private func light(_ kind: String, _ settings: [String: [Double]] = [:]) -> Effect {
        look(EffectKind(package: kind), settings)
    }

    private func brightness(_ c: Color) -> Float { (c.x + c.y + c.z) / 3 }

    @Test func theLightLooksShipInTheLightCategoryInOrder() {
        for kind in Self.kinds {
            let effect = EffectKind(package: kind)
            #expect(effect.definition.package != nil, "\(kind)")
            #expect(effect.category == .light, "\(kind)")
        }
        #expect(EffectKind.all.filter { $0.category == .light }.map(\.rawValue) == Self.kinds)
    }

    @Test func atNoAmountEachDrawsThePictureAsItWas() throws {
        let h = try harness()
        let plain = try draw(Effect(kind: .transform), on: h)
        for kind in Self.kinds {
            let effect = light(kind, ["amount": [0]])
            #expect(effect.isNoOp, "\(kind)")
            let drawn = try draw(effect, on: h)
            #expect(zip(drawn, plain).allSatisfy { close($0, $1, tolerance: 0.001) }, "\(kind)")
        }
    }

    @Test func glowBrightensAroundABrightDotButNotADarkField() throws {
        let h = try harness()
        let plain = try draw(Effect(kind: .transform), on: h)
        let glowing = try draw(light("glow", ["glowRadius": [4]]), on: h)
        // Beside the dot, brighter; far from it, the field as it was.
        #expect(brightness(pixel(glowing, x: 37, y: 18)) > brightness(pixel(plain, x: 37, y: 18)) + 0.05)
        #expect(close(pixel(glowing, x: 2, y: 2), pixel(plain, x: 2, y: 2), tolerance: 0.002))
        // Its color tints the light.
        let blue = try draw(light("glow", ["glowRadius": [4], "glowColor": [0, 0, 1, 1]]), on: h)
        let beside = pixel(blue, x: 37, y: 18)
        #expect(beside.z > beside.x + 0.05)
        // A field below the threshold doesn't glow at all.
        let dark = try harness(dot: nil, field: 0.4)
        let drawn = try draw(light("glow", ["glowRadius": [4]]), on: dark)
        #expect(close(pixel(drawn, x: 32, y: 18), Color(0.4, 0.4, 0.4, 1), tolerance: 0.002))
    }

    @Test func glowInAnHDRTimelineAddsLightAroundHighlightsOnly() throws {
        // PQ: a dot at about 1000 nits on a field at about 5.
        let size = CGSize(width: 32, height: 16)
        let dot = CIImage(color: CIColor(red: 0.75, green: 0.75, blue: 0.75)).cropped(to: CGRect(x: 15, y: 7, width: 2, height: 2))
        let picture = dot.composited(over: CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))).cropped(to: CGRect(origin: .zero, size: size))
        let step = try #require(LookStep(light("glow", ["glowRadius": [3]]), at: .zero))
        let frame = CGRect(origin: .zero, size: size)
        let drawn = LookRenderer.apply(step, to: picture, over: frame, canvas: frame, frame: frame, scale: 1, space: .rec2020PQ)
        var pixels = [SIMD4<Float>](repeating: .zero, count: 32 * 16)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            drawn, toBitmap: &pixels, rowBytes: 32 * 16, bounds: frame, format: .RGBAf, colorSpace: nil
        )
        let beside = pixels[8 * 32 + 19], far = pixels[8 * 32 + 1]
        #expect(beside.x > 0.25)
        #expect(abs(far.x - 0.2) < 0.002)
    }

    @Test func bloomBrightensAroundABrightDotButNotADarkField() throws {
        let h = try harness()
        let plain = try draw(Effect(kind: .transform), on: h)
        let blooming = try draw(light("bloom", ["bloomRadius": [8], "bloomIntensity": [100]]), on: h)
        #expect(brightness(pixel(blooming, x: 37, y: 18)) > brightness(pixel(plain, x: 37, y: 18)) + 0.03)
        // Its long tail reaches further than its core.
        #expect(brightness(pixel(blooming, x: 44, y: 18)) > brightness(pixel(plain, x: 44, y: 18)) + 0.005)
        let dark = try harness(dot: nil, field: 0.4)
        let drawn = try draw(light("bloom"), on: dark)
        #expect(close(pixel(drawn, x: 32, y: 18), Color(0.4, 0.4, 0.4, 1), tolerance: 0.002))
    }

    @Test func halationLeavesAWarmFringeAroundHighlights() throws {
        let h = try harness()
        let plain = try draw(Effect(kind: .transform), on: h)
        let drawn = try draw(light("halation", ["halationRadius": [3]]), on: h)
        let fringe = pixel(drawn, x: 35, y: 18)
        #expect(fringe.x > pixel(plain, x: 35, y: 18).x + 0.05)
        #expect(fringe.x > fringe.z + 0.05)
        #expect(close(pixel(drawn, x: 2, y: 2), pixel(plain, x: 2, y: 2), tolerance: 0.002))
    }

    @Test func vignetteDarkensTheCornersAndLeavesTheMiddle() throws {
        let h = try harness(dot: nil, field: 0.6)
        let drawn = try draw(light("vignette"), on: h)
        #expect(close(pixel(drawn, x: 32, y: 18), Color(0.6, 0.6, 0.6, 1), tolerance: 0.002))
        #expect(pixel(drawn, x: 0, y: 0).x < 0.1)
        #expect(pixel(drawn, x: 63, y: 35).x < 0.1)
        // Toward its color: white lightens the corners instead.
        let white = try draw(light("vignette", ["vignetteColor": [1, 1, 1, 1]]), on: h)
        #expect(pixel(white, x: 0, y: 0).x > 0.9)
        // Moved, the middle it leaves follows its center.
        let moved = try draw(light("vignette", ["vignetteCenter": [-28, -14]]), on: h)
        #expect(close(pixel(moved, x: 4, y: 4), Color(0.6, 0.6, 0.6, 1), tolerance: 0.002))
        #expect(pixel(moved, x: 63, y: 35).x < 0.1)
    }

    @Test func spotlightLightsItsPoolAndDimsAroundIt() throws {
        let h = try harness(dot: nil, field: 0.4)
        let drawn = try draw(light("spotlight", ["spotCenter": [-16, 0], "spotSize": [20, 20], "spotColor": [1, 1, 1, 1]]), on: h)
        #expect(pixel(drawn, x: 16, y: 18).x > 0.42)
        #expect(pixel(drawn, x: 50, y: 18).x < 0.25)
    }

    @Test func lightRaysStreamAwayFromTheirSource() throws {
        let h = try harness()
        let plain = try draw(Effect(kind: .transform), on: h)
        // The source left of the dot: rays go on to its right, not its left.
        let drawn = try draw(light("lightRays", ["rayCenter": [-24, 0]]), on: h)
        let after = brightness(pixel(drawn, x: 42, y: 18)) - brightness(pixel(plain, x: 42, y: 18))
        let before = brightness(pixel(drawn, x: 22, y: 18)) - brightness(pixel(plain, x: 22, y: 18))
        #expect(after > 0.02)
        #expect(after > before * 4)
        // Off the line through the source and the dot, nothing.
        #expect(close(pixel(drawn, x: 42, y: 2), pixel(plain, x: 42, y: 2), tolerance: 0.002))
    }

    @Test func lensFlareShinesFromItsSource() throws {
        let h = try harness(dot: nil)
        let drawn = try draw(light("lensFlare", ["flareCenter": [-20, -10], "flareSize": [4]]), on: h)
        let atSource = pixel(drawn, x: 12, y: 8)
        #expect(brightness(atSource) > 0.8)
        // Brightest at the source, fainter away from it.
        #expect(brightness(atSource) > brightness(pixel(drawn, x: 12, y: 30)) + 0.3)
    }

    @Test func lightLeakComesInFromItsSideAndDrifts() throws {
        let h = try harness(dot: nil)
        let drawn = try draw(light("lightLeak"), on: h)
        let left = brightness(pixel(drawn, x: 1, y: 18)), right = brightness(pixel(drawn, x: 62, y: 18))
        #expect(left > right + 0.2)
        #expect(close(pixel(drawn, x: 62, y: 18), Color(0.1, 0.1, 0.1, 1), tolerance: 0.01))
        // Turned to come from the top.
        let top = try draw(light("lightLeak", ["leakAngle": [90]]), on: h)
        #expect(brightness(pixel(top, x: 32, y: 0)) > brightness(pixel(top, x: 32, y: 35)) + 0.2)
        // It moves on its own over time.
        let later = try draw(light("lightLeak"), on: h, at: 2)
        #expect(zip(drawn, later).contains { !close($0, $1, tolerance: 0.02) })
        #expect(EffectKind(package: "lightLeak").definition.package?.rateControls.isEmpty == false)
    }
}
