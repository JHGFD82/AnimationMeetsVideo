import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The color math, restated in double precision as the reference the
/// kernel is held to.
private enum ColorReference {
    typealias V = SIMD3<Double>

    static func sgn(_ x: Double) -> Double { x < 0 ? -1 : 1 }

    // MARK: Transfer functions

    static func dec709(_ e: Double) -> Double {
        let a = abs(e)
        return sgn(e) * (a < 0.081 ? a / 4.5 : pow((a + 0.099) / 1.099, 1 / 0.45))
    }

    static func enc709(_ l: Double) -> Double {
        let a = abs(l)
        return sgn(l) * (a < 0.018 ? 4.5 * a : 1.099 * pow(a, 0.45) - 0.099)
    }

    static let pq = (m1: 0.1593017578125, m2: 78.84375, c1: 0.8359375, c2: 18.8515625, c3: 18.6875)

    static func decPQ(_ e: Double) -> Double {
        let p = pow(min(abs(e), 1), 1 / pq.m2)
        let y = pow(max(p - pq.c1, 0) / (pq.c2 - pq.c3 * p), 1 / pq.m1)
        return sgn(e) * y * 10000 / 203
    }

    static func encPQ(_ l: Double) -> Double {
        let p = pow(abs(l) * 203 / 10000, pq.m1)
        return sgn(l) * pow((pq.c1 + pq.c2 * p) / (1 + pq.c3 * p), pq.m2)
    }

    static let hlg = (a: 0.17883277, b: 0.28466892, c: 0.55991073)
    static var hlgWhite: Double { (exp((0.75 - hlg.c) / hlg.a) + hlg.b) / 12 }

    static func decHLG(_ e: Double) -> Double {
        let a = abs(e)
        let s = a <= 0.5 ? a * a / 3 : (exp((a - hlg.c) / hlg.a) + hlg.b) / 12
        return sgn(e) * s / hlgWhite
    }

    static func encHLG(_ l: Double) -> Double {
        let s = abs(l) * hlgWhite
        return sgn(l) * (s <= 1.0 / 12 ? (3 * s).squareRoot() : hlg.a * log(12 * s - hlg.b) + hlg.c)
    }

    static func toLinear(_ e: Double, _ space: ProjectColorSpace) -> Double {
        switch space {
        case .rec709: dec709(e)
        case .rec2020PQ: decPQ(e)
        case .rec2020HLG: decHLG(e)
        }
    }

    static func fromLinear(_ l: Double, _ space: ProjectColorSpace) -> Double {
        switch space {
        case .rec709: enc709(l)
        case .rec2020PQ: encPQ(l)
        case .rec2020HLG: encHLG(l)
        }
    }

    static func lin2log(_ l: Double) -> Double {
        l <= 0.0078125 ? 10.5402377416545 * l + 0.0729055341958355 : (log2(l) + 9.72) / 17.52
    }

    static func log2lin(_ t: Double) -> Double {
        t <= 0.155251141552511 ? (t - 0.0729055341958355) / 10.5402377416545 : exp2(t * 17.52 - 9.72)
    }

    static let black = 0.0729055341958355, mid = 0.4135884, white = 0.5547945

    // MARK: Grading

    /// The straight color `encoded` comes out as after `ops`, in a timeline of `space`.
    static func grade(_ encoded: V, _ ops: [ColorOp], in space: ProjectColorSpace) -> V {
        var c = encoded
        var state = 0
        func map(_ c: V, _ f: (Double) -> Double) -> V { V(f(c.x), f(c.y), f(c.z)) }
        for op in ops {
            let v = SIMD4<Double>(Double(op.value.x), Double(op.value.y), Double(op.value.z), Double(op.value.w))
            if op.kind.worksInLinearLight {
                if state == 0 { c = map(c) { toLinear($0, space) } } else if state == 2 { c = map(c, log2lin) }
                state = 1
            } else {
                if state == 0 { c = map(map(c) { toLinear($0, space) }, lin2log) } else if state == 1 { c = map(c, lin2log) }
                state = 2
            }
            switch op.kind {
            case .exposure: c *= exp2(v.x)
            case .temperature: c *= V(exp2(0.5 * v.x), 1, exp2(-0.5 * v.x))
            case .tint: c *= V(exp2(0.25 * v.x), exp2(-0.5 * v.x), exp2(0.25 * v.x))
            case .gain: c *= V(v.x * v.y, v.x * v.z, v.x * v.w)
            case .contrast: c = V(repeating: mid) + (c - V(repeating: mid)) * v.x
            case .saturation:
                let y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
                c = V(repeating: y) + (c - V(repeating: y)) * v.x
            case .lift:
                let lift = V(v.x + v.y, v.x + v.z, v.x + v.w)
                c = V(
                    c.x + lift.x * min(max(1 - (c.x - black) / (white - black), 0), 1),
                    c.y + lift.y * min(max(1 - (c.y - black) / (white - black), 0), 1),
                    c.z + lift.z * min(max(1 - (c.z - black) / (white - black), 0), 1)
                )
            case .gamma:
                let g = V(max(v.x * v.y, 0.0001), max(v.x * v.z, 0.0001), max(v.x * v.w, 0.0001))
                func bend(_ t: Double, _ g: Double) -> Double {
                    let x = (t - black) / (white - black)
                    return black + (x > 0 ? pow(x, 1 / g) : x) * (white - black)
                }
                c = V(bend(c.x, g.x), bend(c.y, g.y), bend(c.z, g.z))
            }
        }
        if state == 2 { c = map(c, log2lin) }
        if state != 0 { c = map(c) { fromLinear($0, space) } }
        return c
    }
}

@Suite struct ColorTests {
    private let samples: [SIMD3<Double>] = [
        SIMD3(0.12, 0.40, 0.75), SIMD3(0.55, 0.30, 0.20), SIMD3(0.8, 0.8, 0.7), SIMD3(0.05, 0.1, 0.02),
    ]

    private func draw(_ ops: [ColorOp], on color: SIMD3<Double>, alpha: Float = 1, space: ProjectColorSpace = .rec709) throws -> SIMD4<Float> {
        // Controls make the steps; here the steps are given, through a
        // stack of Color effects holding the matching controls.
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(Float(color.x), Float(color.y), Float(color.z), alpha))
        var effect = Effect(kind: .color, controls: [])
        for op in ops { effect.controls.append(control(for: op)) }
        var clip = CompositorHarness.clip(track: 1, effects: [effect])
        clip.stack.colorSpace = space
        let frame = try harness.draw([clip])
        return harness.pixel(frame, x: 5, y: 3)
    }

    /// The control that makes `op`.
    private func control(for op: ColorOp) -> EffectControl {
        let kind: ControlKind
        var values: [Double]
        let v = op.value
        switch op.kind {
        case .exposure: kind = .exposure; values = [Double(v.x)]
        case .temperature: kind = .temperature; values = [Double(v.x) * 100]
        case .tint: kind = .tint; values = [Double(v.x) * 100]
        case .contrast: kind = .contrast; values = [Double(v.x) * 100]
        case .saturation: kind = .saturation; values = [Double(v.x) * 100]
        case .lift: kind = .lift; values = [Double(v.x), Double(v.y), Double(v.z), Double(v.w)]
        case .gamma: kind = .gamma; values = [Double(v.x), Double(v.y), Double(v.z), Double(v.w)]
        case .gain: kind = .gain; values = [Double(v.x), Double(v.y), Double(v.z), Double(v.w)]
        }
        var control = EffectControl(kind: kind)
        control.number = AnimatedValue(ComponentValue(values: values))
        return control
    }

    private func expect(_ ops: [ColorOp], space: ProjectColorSpace, tolerance: Double = 0.012, sourceLocation: SourceLocation = #_sourceLocation) throws {
        for color in samples {
            let drawn = try draw(ops, on: color, space: space)
            let expected = ColorReference.grade(color, ops, in: space)
            for channel in 0..<3 {
                #expect(
                    abs(Double(drawn[channel]) - expected[channel]) <= tolerance,
                    "\(ops.map(\.kind)) in \(space) on \(color): \(drawn) vs \(expected)", sourceLocation: sourceLocation
                )
            }
        }
    }

    private static let spaces = ProjectColorSpace.allCases

    @Test(arguments: ProjectColorSpace.allCases)
    func exposureDoublesLinearLightWhateverTheSpace(space: ProjectColorSpace) throws {
        let color = SIMD3<Double>(0.2, 0.3, 0.35)
        let drawn = try draw([ColorOp(kind: .exposure, value: SIMD4(1, 0, 0, 0))], on: color, space: space)
        for channel in 0..<3 {
            let before = ColorReference.toLinear(color[channel], space)
            let after = ColorReference.toLinear(Double(drawn[channel]), space)
            #expect(abs(after / before - 2) < 0.03, "\(space) channel \(channel): \(after / before)")
        }
    }

    @Test(arguments: ProjectColorSpace.allCases)
    func everyKindOfStepMatchesTheReference(space: ProjectColorSpace) throws {
        try expect([ColorOp(kind: .exposure, value: SIMD4(-0.7, 0, 0, 0))], space: space)
        try expect([ColorOp(kind: .temperature, value: SIMD4(0.6, 0, 0, 0))], space: space)
        try expect([ColorOp(kind: .tint, value: SIMD4(-0.5, 0, 0, 0))], space: space)
        try expect([ColorOp(kind: .gain, value: SIMD4(1.2, 1, 0.9, 1.1))], space: space)
        try expect([ColorOp(kind: .contrast, value: SIMD4(1.4, 0, 0, 0))], space: space)
        try expect([ColorOp(kind: .saturation, value: SIMD4(0.4, 0, 0, 0))], space: space)
        try expect([ColorOp(kind: .lift, value: SIMD4(0.05, 0, 0.02, -0.03))], space: space)
        try expect([ColorOp(kind: .gamma, value: SIMD4(1.3, 1, 1.1, 0.9))], space: space)
    }

    @Test(arguments: ProjectColorSpace.allCases)
    func stepsRunInTheOrderListedAcrossWorkingSpaces(space: ProjectColorSpace) throws {
        let ops = [
            ColorOp(kind: .exposure, value: SIMD4(0.5, 0, 0, 0)),
            ColorOp(kind: .contrast, value: SIMD4(1.3, 0, 0, 0)),
            ColorOp(kind: .gain, value: SIMD4(0.9, 1, 1, 1)),
            ColorOp(kind: .saturation, value: SIMD4(1.5, 0, 0, 0)),
        ]
        try expect(ops, space: space)
        // Contrast and exposure don't commute, so the order listed shows.
        let gray = SIMD3<Double>(0.4, 0.4, 0.4)
        let a = try draw([ops[0], ops[1]], on: gray, space: space)
        let b = try draw([ops[1], ops[0]], on: gray, space: space)
        #expect(abs(a.x - b.x) > 0.003)
        #expect(abs(Double(a.x) - ColorReference.grade(gray, [ops[0], ops[1]], in: space).x) < 0.012)
        #expect(abs(Double(b.x) - ColorReference.grade(gray, [ops[1], ops[0]], in: space).x) < 0.012)
    }

    @Test func aGradeLooksTheSameInEveryColorSpace() throws {
        // The same light, encoded for each space, graded with the same
        // steps, is the same light after.
        let light = SIMD3<Double>(0.18, 0.25, 0.3)
        let ops = [
            ColorOp(kind: .exposure, value: SIMD4(0.5, 0, 0, 0)),
            ColorOp(kind: .contrast, value: SIMD4(1.25, 0, 0, 0)),
            ColorOp(kind: .saturation, value: SIMD4(1.3, 0, 0, 0)),
        ]
        var results: [SIMD3<Double>] = []
        for space in ProjectColorSpace.allCases {
            let encoded = SIMD3(
                ColorReference.fromLinear(light.x, space), ColorReference.fromLinear(light.y, space), ColorReference.fromLinear(light.z, space)
            )
            let drawn = try draw(ops, on: encoded, space: space)
            results.append(SIMD3(
                ColorReference.toLinear(Double(drawn.x), space), ColorReference.toLinear(Double(drawn.y), space),
                ColorReference.toLinear(Double(drawn.z), space)
            ))
        }
        for result in results.dropFirst() {
            for channel in 0..<3 { #expect(abs(result[channel] - results[0][channel]) / results[0][channel] < 0.04) }
        }
    }

    @Test func gradingLeavesAlphaAloneAndWorksOnTheColorNotTheMultipliedColor() throws {
        let color = SIMD3<Double>(0.4, 0.5, 0.2)
        let op = ColorOp(kind: .exposure, value: SIMD4(0.5, 0, 0, 0))
        let drawn = try draw([op], on: color, alpha: 0.5)
        let expected = ColorReference.grade(color, [op], in: .rec709)
        // Over the opaque black under the root, what shows is the graded
        // color at half strength.
        #expect(abs(drawn.w - 1) < 0.01)
        for channel in 0..<3 { #expect(abs(Double(drawn[channel]) - expected[channel] * 0.5) < 0.02) }
    }

    @Test func controlsAtTheirDefaultsMakeNoSteps() {
        let effect = Effect(kind: .color)
        let steps = StackFolding.steps(effects: [effect], anchorPoint: AnimatedValue(.zero), at: .zero, center: .zero)
        #expect(steps.isEmpty)
    }

    @Test func colorStepsAndMovesFoldTogetherInAnyOrder() {
        var move = Effect(kind: .transform, controls: [EffectControl(kind: .position)])
        move.controls[0].number = AnimatedValue(ComponentValue(values: [3, 0]))
        var exposure = Effect(kind: .color, controls: [EffectControl(kind: .exposure)])
        exposure.controls[0].number = AnimatedValue(ComponentValue(values: [1]))
        func steps(_ effects: [Effect]) -> [ResolvedStep] {
            StackFolding.steps(effects: effects, anchorPoint: AnimatedValue(.zero), at: .zero, center: .zero)
        }
        // Grading doesn't depend on where a pixel is, so moving before or
        // after it is the same, and a run is one move and one grade.
        #expect(steps([move, exposure]) == steps([exposure, move]))
        #expect(steps([move, exposure, move]).count == 2)
        // A Blending step between them does read the backdrop, so it splits.
        var blend = Effect(kind: .blending)
        blend.controls[0].blendMode = .multiply
        #expect(steps([exposure, blend, move]).count == 3)
    }

    @Test func gradingPlaysItsPartInDrawnOrderRelativeToBlending() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0.5, 0.5, 0.5, 1))
        try harness.addSolid(track: 2, SIMD4(0.4, 0.6, 0.3, 1))
        var grade = Effect(kind: .color, controls: [EffectControl(kind: .exposure)])
        grade.controls[0].number = AnimatedValue(ComponentValue(values: [1]))
        var blend = Effect(kind: .blending)
        blend.controls[0].blendMode = .multiply
        let gradedThenBlended = try harness.draw([CompositorHarness.clip(track: 2, effects: [grade, blend]), CompositorHarness.clip(track: 1)])
        let blendedThenGraded = try harness.draw([CompositorHarness.clip(track: 2, effects: [blend, grade]), CompositorHarness.clip(track: 1)])
        #expect(!close(harness.pixel(gradedThenBlended, x: 4, y: 4), harness.pixel(blendedThenGraded, x: 4, y: 4), tolerance: 0.005))
    }
}
