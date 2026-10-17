import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The blend formulas, written out again here as the reference the
/// kernels are held to (W3C compositing and blending, level 1).
private enum Reference {
    typealias V = SIMD3<Float>

    static func lum(_ c: V) -> Float { 0.3 * c.x + 0.59 * c.y + 0.11 * c.z }

    static func clipColor(_ c: V) -> V {
        var c = c
        let l = lum(c)
        let n = min(c.x, c.y, c.z), x = max(c.x, c.y, c.z)
        if n < 0 { c = l + (c - l) * l / (l - n) }
        if x > 1 { c = l + (c - l) * (1 - l) / (x - l) }
        return c
    }

    static func setLum(_ c: V, _ l: Float) -> V { clipColor(c + (l - lum(c))) }
    static func sat(_ c: V) -> Float { max(c.x, c.y, c.z) - min(c.x, c.y, c.z) }

    static func setSat(_ c: V, _ s: Float) -> V {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z)
        return mx > mn ? (c - mn) * s / (mx - mn) : V(repeating: 0)
    }

    static func channel(_ cb: V, _ cs: V, _ f: (Float, Float) -> Float) -> V {
        V(f(cb.x, cs.x), f(cb.y, cs.y), f(cb.z, cs.z))
    }

    static func hardLight(_ cb: Float, _ cs: Float) -> Float {
        cs <= 0.5 ? cb * 2 * cs : cb + (2 * cs - 1) - cb * (2 * cs - 1)
    }

    /// B(backdrop, source).
    static func blend(_ mode: BlendMode, _ cb: V, _ cs: V) -> V {
        switch mode {
        case .normal: cs
        case .darken: pointwiseMin(cb, cs)
        case .multiply: cb * cs
        case .colorBurn: channel(cb, cs) { b, s in b >= 1 ? 1 : s <= 0 ? 0 : 1 - min(1, (1 - b) / s) }
        case .linearBurn: pointwiseMax(cb + cs - 1, V(repeating: 0))
        case .lighten: pointwiseMax(cb, cs)
        case .screen: cb + cs - cb * cs
        case .colorDodge: channel(cb, cs) { b, s in b <= 0 ? 0 : s >= 1 ? 1 : min(1, b / (1 - s)) }
        case .add: cb + cs
        case .overlay: channel(cs, cb, hardLight)
        case .softLight: channel(cb, cs) { b, s in
            if s <= 0.5 { return b - (1 - 2 * s) * b * (1 - b) }
            let d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : b.squareRoot()
            return b + (2 * s - 1) * (d - b)
        }
        case .hardLight: channel(cb, cs, hardLight)
        case .difference: channel(cb, cs) { abs($0 - $1) }
        case .exclusion: cb + cs - 2 * cb * cs
        case .subtract: pointwiseMax(cb - cs, V(repeating: 0))
        case .divide: channel(cb, cs) { b, s in s <= 0 ? 1 : min(b / s, 1) }
        case .hue: setLum(setSat(cs, sat(cb)), lum(cb))
        case .saturation: setLum(setSat(cb, sat(cs)), lum(cb))
        case .color: setLum(cs, lum(cb))
        case .luminosity: setLum(cb, lum(cs))
        }
    }

    /// The straight RGBA a clip `cs` (alpha `ac`) blended with `cb` (alpha
    /// `ab`) comes out as.
    static func result(_ mode: BlendMode, clip: SIMD4<Float>, backdrop: SIMD4<Float>, amount: Float = 1, keepsBackdrop: Bool = false) -> SIMD4<Float> {
        let cs = V(clip.x, clip.y, clip.z), cb = V(backdrop.x, backdrop.y, backdrop.z)
        let ac = clip.w, ab = backdrop.w
        let blended = (1 - ab) * cs + ab * blend(mode, cb, cs)
        let color = cs + amount * (blended - cs)
        guard keepsBackdrop else { return SIMD4(color.x, color.y, color.z, ac) }
        let alpha = ac + ab * (1 - ac)
        let premultiplied = color * ac + cb * ab * (1 - ac)
        return alpha > 0 ? SIMD4(premultiplied.x / alpha, premultiplied.y / alpha, premultiplied.z / alpha, alpha) : .zero
    }
}

@Suite struct BlendingTests {
    private func blending(_ mode: BlendMode, amount: Double = 100, against: UUID? = nil) -> Effect {
        var effect = Effect(kind: .blending)
        effect.controls[0].blendMode = mode
        effect.controls[1].number = AnimatedValue(ComponentValue(values: [amount]))
        effect.against = against
        return effect
    }

    private func transform(_ controls: [(ControlKind, [Double])]) -> Effect {
        var effect = Effect(kind: .transform, controls: [])
        for (kind, values) in controls {
            var control = EffectControl(kind: kind)
            control.number = AnimatedValue(ComponentValue(values: values))
            effect.controls.append(control)
        }
        return effect
    }

    @Test(arguments: BlendMode.allCases)
    func everyModeMatchesItsFormulaOverAnOpaqueBackdrop(mode: BlendMode) throws {
        var harness = CompositorHarness()
        let backdrop = SIMD4<Float>(0.62, 0.31, 0.44, 1)
        let source = SIMD4<Float>(0.18, 0.55, 0.83, 1)
        try harness.addSolid(track: 1, backdrop)
        try harness.addSolid(track: 2, source)
        let frame = try harness.draw([
            CompositorHarness.clip(track: 2, effects: [blending(mode)]),
            CompositorHarness.clip(track: 1),
        ])
        let expected = Reference.result(mode, clip: source, backdrop: backdrop)
        #expect(close(harness.pixel(frame, x: 8, y: 4), expected), "\(mode): \(harness.pixel(frame, x: 8, y: 4)) vs \(expected)")
    }

    @Test(arguments: [BlendMode.multiply, .screen, .overlay, .softLight, .hue, .luminosity, .difference])
    func modesBlendWithAColorfulSecondPair(mode: BlendMode) throws {
        var harness = CompositorHarness()
        let backdrop = SIMD4<Float>(0.9, 0.2, 0.05, 1)
        let source = SIMD4<Float>(0.35, 0.8, 0.4, 1)
        try harness.addSolid(track: 1, backdrop)
        try harness.addSolid(track: 2, source)
        let frame = try harness.draw([
            CompositorHarness.clip(track: 2, effects: [blending(mode)]),
            CompositorHarness.clip(track: 1),
        ])
        #expect(close(harness.pixel(frame, x: 3, y: 2), Reference.result(mode, clip: source, backdrop: backdrop)))
    }

    @Test func amountMixesTheClipTowardTheBlendedColor() throws {
        var harness = CompositorHarness()
        let backdrop = SIMD4<Float>(0.5, 0.5, 0.5, 1)
        let source = SIMD4<Float>(0.8, 0.4, 0.2, 1)
        try harness.addSolid(track: 1, backdrop)
        try harness.addSolid(track: 2, source)
        func drawn(_ amount: Double) throws -> SIMD4<Float> {
            let frame = try harness.draw([
                CompositorHarness.clip(track: 2, effects: [blending(.multiply, amount: amount)]),
                CompositorHarness.clip(track: 1),
            ])
            return harness.pixel(frame, x: 8, y: 4)
        }
        #expect(close(try drawn(0), source))
        #expect(close(try drawn(50), Reference.result(.multiply, clip: source, backdrop: backdrop, amount: 0.5)))
        #expect(close(try drawn(100), Reference.result(.multiply, clip: source, backdrop: backdrop)))
    }

    @Test func normalIsANoOpAndAnEmptyBackdropIsNothingToBlendWith() throws {
        var harness = CompositorHarness()
        let source = SIMD4<Float>(0.8, 0.4, 0.2, 0.7)
        try harness.addSolid(track: 2, source)
        // Nothing under it in a nested timeline: blending against the
        // backdrop leaves the clip as it is.
        let alone = try harness.draw([CompositorHarness.group([CompositorHarness.clip(track: 2, effects: [blending(.difference)])])])
        let plain = try harness.draw([CompositorHarness.group([CompositorHarness.clip(track: 2)])])
        #expect(close(harness.pixel(alone, x: 4, y: 4), harness.pixel(plain, x: 4, y: 4)))
        let normal = try harness.draw([CompositorHarness.group([CompositorHarness.clip(track: 2, effects: [blending(.normal)])])])
        #expect(close(harness.pixel(normal, x: 4, y: 4), harness.pixel(plain, x: 4, y: 4)))
    }

    @Test func aTranslucentBackdropCountsInProportion() throws {
        var harness = CompositorHarness()
        let backdrop = SIMD4<Float>(0.6, 0.2, 0.9, 0.4)
        let source = SIMD4<Float>(0.3, 0.7, 0.5, 1)
        try harness.addSolid(track: 1, backdrop)
        try harness.addSolid(track: 2, source)
        // Both inside one nested timeline, so the backdrop is translucent
        // there rather than the opaque black under the root.
        let frame = try harness.draw([CompositorHarness.group([
            CompositorHarness.clip(track: 2, effects: [blending(.multiply)]),
            CompositorHarness.clip(track: 1),
        ])])
        #expect(close(harness.pixel(frame, x: 8, y: 4), Reference.result(.multiply, clip: source, backdrop: backdrop)))
    }

    @Test func againstBlendsWithTheClipAsItWasBeforeAnEarlierEffect() throws {
        var harness = CompositorHarness()
        let color = SIMD4<Float>(0.3, 0.5, 0.7, 1)
        try harness.addSolid(track: 1, color)
        // Shrunk to half size, then screened against the picture as it was
        // before that: the shrunk picture is blended with the full one, and
        // the full one shows around it.
        let shrink = transform([(.scale, [50, 50])])
        let screen = blending(.screen, against: shrink.id)
        let frame = try harness.draw([CompositorHarness.clip(track: 1, effects: [shrink, screen])])
        let inside = Reference.result(.screen, clip: color, backdrop: color, keepsBackdrop: true)
        #expect(close(harness.pixel(frame, x: 8, y: 4), inside))
        #expect(close(harness.pixel(frame, x: 1, y: 1), color))
        #expect(close(harness.pixel(frame, x: 8, y: 4), color) == false)
    }

    @Test func aBlendNeedsItsTargetAboveIt() throws {
        var harness = CompositorHarness()
        let color = SIMD4<Float>(0.3, 0.5, 0.7, 1)
        try harness.addSolid(track: 1, color)
        let shrink = transform([(.scale, [50, 50])])
        // Targets an effect below it, so it can't read it and does nothing.
        let screen = blending(.screen, against: shrink.id)
        let drawn = try harness.draw([CompositorHarness.clip(track: 1, effects: [screen, shrink])])
        let plain = try harness.draw([CompositorHarness.clip(track: 1, effects: [shrink])])
        for (x, y) in [(8, 4), (1, 1), (14, 6)] {
            #expect(close(harness.pixel(drawn, x: x, y: y), harness.pixel(plain, x: x, y: y)))
        }
    }

    @Test func aMoveAfterABlendCarriesWhatWasBlended() throws {
        var harness = CompositorHarness()
        // A backdrop that is red on the left and blue on the right.
        let left = SIMD4<Float>(0.9, 0.1, 0.1, 1), right = SIMD4<Float>(0.1, 0.1, 0.9, 1)
        try harness.addPicture(track: 1) { x, _ in x < 0.5 ? left : right }
        let gray = SIMD4<Float>(0.5, 0.5, 0.5, 1)
        try harness.addSolid(track: 2, gray)
        let shiftRight = transform([(.position, [8, 0])])
        let multiplied = harness.pixelAfter([CompositorHarness.clip(track: 2, effects: [blending(.multiply), shiftRight]), CompositorHarness.clip(track: 1)])
        // Multiplied first, then moved half a frame right: the right half
        // shows what the left half was blended with.
        let expected = Reference.result(.multiply, clip: gray, backdrop: left)
        #expect(close(try multiplied(12, 4), expected))
        let moved = harness.pixelAfter([CompositorHarness.clip(track: 2, effects: [shiftRight, blending(.multiply)]), CompositorHarness.clip(track: 1)])
        // Moved first: the picture only covers the right half, where it
        // blends with blue.
        #expect(close(try moved(12, 4), Reference.result(.multiply, clip: gray, backdrop: right)))
    }

    @Test func blendsOffAMovedPictureStillWorkWhereItLandsOnTheFrame() throws {
        var harness = CompositorHarness()
        let backdrop = SIMD4<Float>(0.2, 0.6, 0.4, 1), source = SIMD4<Float>(0.9, 0.3, 0.5, 1)
        try harness.addSolid(track: 1, backdrop)
        try harness.addSolid(track: 2, source)
        let big = transform([(.scale, [400, 400])])
        let frame = try harness.draw([CompositorHarness.clip(track: 2, effects: [big, blending(.screen)]), CompositorHarness.clip(track: 1)])
        #expect(close(harness.pixel(frame, x: 8, y: 4), Reference.result(.screen, clip: source, backdrop: backdrop)))
    }
}

private extension CompositorHarness {
    /// A function reading a pixel of the frame drawn from `clips`.
    func pixelAfter(_ clips: [DrawClip]) -> (Int, Int) throws -> SIMD4<Float> {
        { x, y in
            let frame = try draw(clips)
            return pixel(frame, x: x, y: y)
        }
    }
}
