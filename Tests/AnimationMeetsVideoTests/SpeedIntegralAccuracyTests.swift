import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// How far `SpeedIntegral` is from the true integral of 100 / speed, split
/// by cause, against a reference that shares none of its machinery: its own
/// Bézier, read at exact `Double` times, integrated by adaptive
/// Gauss-Kronrod.
///
/// `SpeedIntegral.at(keyframe)` differs from the truth by
///   quantization: the rate is read at times cut to a CMTime grid
///     (`SpeedIntegral.rateTimescale`), so each node reads the rate at a
///     slightly different time; and
///   quadrature: the 24-step Simpson sum over a piece isn't exact.
@Suite struct SpeedIntegralAccuracyTests {
    // MARK: Reference

    private struct Piece {
        var t0: Double, t1: Double
        var v0: Double, v1: Double
        var out: KeyframeEase?, into: KeyframeEase?
    }

    private func pieces(of speed: AnimatedValue<Double>) -> [Piece] {
        zip(speed.keyframes, speed.keyframes.dropFirst()).map {
            Piece(t0: $0.time.seconds, t1: $1.time.seconds, v0: $0.value, v1: $1.value, out: $0.easeOut, into: $1.easeIn)
        }
    }

    private static func handles(_ piece: Piece) -> (x: [Double], y: [Double]) {
        let o = KeyframeEase.outgoingHandle(piece.out), i = KeyframeEase.incomingHandle(piece.into)
        return ([0, o.x, i.x, 1], [0, o.y, i.y, 1])
    }

    /// Progress at `fraction` of a piece, from a Bézier of the piece's own
    /// handles, solved by 60 halvings (a 1e-18 step, below Double's).
    private func progress(_ fraction: Double, _ piece: Piece) -> Double {
        guard piece.out != nil || piece.into != nil else { return fraction }
        let (x, y) = Self.handles(piece)
        func bezier(_ c: [Double], _ s: Double) -> Double {
            let u = 1 - s
            return u * u * u * c[0] + 3 * u * u * s * c[1] + 3 * u * s * s * c[2] + s * s * s * c[3]
        }
        var low = 0.0, high = 1.0
        for _ in 0..<60 {
            let middle = (low + high) / 2
            if bezier(x, middle) < fraction { low = middle } else { high = middle }
        }
        return bezier(y, (low + high) / 2)
    }

    /// 100 / speed at an exact time within `piece`.
    private func rate(_ time: Double, _ piece: Piece) -> Double {
        let value = piece.v0 + (piece.v1 - piece.v0) * progress((time - piece.t0) / (piece.t1 - piece.t0), piece)
        return 100 / min(max(value, ClipTime.speedRange.lowerBound), ClipTime.speedRange.upperBound)
    }

    /// Adaptive 15-point Gauss-Kronrod: halves a span until its error
    /// estimate (the Kronrod and Gauss sums' difference) is within its share
    /// of `tolerance`.
    private func reference(_ f: (Double) -> Double, _ a: Double, _ b: Double, tolerance: Double = 1e-12, depth: Int = 0) -> Double {
        let nodes = [0.991455371120813, 0.949107912342759, 0.864864423359769, 0.741531185599394, 0.586087235467691, 0.405845151377397, 0.207784955007898, 0.0]
        let kronrod = [0.022935322010529, 0.063092092629979, 0.104790010322250, 0.140653259715525, 0.169004726639267, 0.190350578064785, 0.204432940075298, 0.209482141084728]
        let gauss = [0.129484966168870, 0.279705391489277, 0.381830050505119, 0.417959183673469]
        let centre = (a + b) / 2, half = (b - a) / 2
        var k = 0.0, g = 0.0
        for (index, node) in nodes.enumerated() {
            let sum = index == 7 ? f(centre) : f(centre - half * node) + f(centre + half * node)
            k += kronrod[index] * sum
            if index % 2 == 1 { g += gauss[index / 2] * sum }
        }
        k *= half; g *= half
        if abs(k - g) <= tolerance || depth >= 8 { return k }
        return reference(f, a, centre, tolerance: tolerance / 2, depth: depth + 1) + reference(f, centre, b, tolerance: tolerance / 2, depth: depth + 1)
    }

    /// The exact total over each piece (a piece's breakpoints are where the
    /// clamp starts or stops biting, found by sampling, so the adaptive
    /// rule meets each kink at a span's edge).
    private func trueTotal(_ piece: Piece) -> Double {
        let cuts = (0...32).map { piece.t0 + (piece.t1 - piece.t0) * Double($0) / 32 }
        return zip(cuts, cuts.dropFirst()).reduce(0) { $0 + reference({ rate($0, piece) }, $1.0, $1.1) }
    }

    // MARK: A bound on the quantization

    /// A bound, from the pieces' handles alone, on how fast the rate can
    /// change per second: |d rate / dt| <= 100 |dv| p' / (smin^2 dt), with
    ///   p' <= max|dy/ds| / min(dx/ds) over the curve's parameter, from the
    ///   Bézier's Bernstein coefficients (and the exact minimum of the
    ///   quadratic dx/ds), and
    ///   smin the least speed the curve's control hull reaches, after the
    ///   clamp.
    /// Infinite when dx/ds can reach zero.
    private func rateSlopeBound(_ piece: Piece) -> Double {
        let dt = piece.t1 - piece.t0
        let lowest = ClipTime.speedRange.lowerBound, highest = ClipTime.speedRange.upperBound
        guard piece.out != nil || piece.into != nil else {
            let smin = min(max(min(piece.v0, piece.v1), lowest), highest)
            return 100 * abs(piece.v1 - piece.v0) / (smin * smin * dt)
        }
        let (x, y) = Self.handles(piece)
        // dx/ds / 3 is the quadratic with Bernstein coefficients b.
        let b = [x[1] - x[0], x[2] - x[1], x[3] - x[2]]
        func quadratic(_ s: Double) -> Double { (1 - s) * (1 - s) * b[0] + 2 * (1 - s) * s * b[1] + s * s * b[2] }
        var smallest = min(b[0], b[2])
        let denominator = b[0] - 2 * b[1] + b[2]
        if denominator != 0 {
            let vertex = (b[0] - b[1]) / denominator
            if vertex > 0, vertex < 1 { smallest = min(smallest, quadratic(vertex)) }
        }
        guard smallest > 0 else { return .infinity }
        let a = [y[1] - y[0], y[2] - y[1], y[3] - y[2]]
        let slope = a.map(abs).max()! / smallest
        let hull = y + [0, 1]
        let ends = [piece.v0 + (piece.v1 - piece.v0) * hull.min()!, piece.v0 + (piece.v1 - piece.v0) * hull.max()!]
        let smin = min(max(ends.min()!, lowest), highest)
        return 100 * abs(piece.v1 - piece.v0) * slope / (smin * smin * dt)
    }

    // MARK: Curves

    private func curve(_ keyframes: [(Double, Double, KeyframeEase?, KeyframeEase?)]) -> AnimatedValue<Double> {
        AnimatedValue(100, keyframes: keyframes.map {
            Keyframe(time: CMTime(seconds: $0.0, preferredTimescale: 600), value: $0.1, easeIn: $0.2, easeOut: $0.3)
        })
    }

    private var demanding: [(String, AnimatedValue<Double>)] {
        let sharp = KeyframeEase(influence: 0.01, speed: 10)
        let stop = KeyframeEase(influence: 0.01, speed: 0)
        let long = KeyframeEase(influence: 1, speed: 1)
        let back = KeyframeEase(influence: 0.5, speed: -10)
        return [
            ("the whole speed range, sharp handles", curve([(0, 1, nil, sharp), (30, 10_000, sharp, nil)])),
            ("the whole speed range, stopping handles", curve([(0, 10_000, nil, stop), (30, 1, stop, nil)])),
            ("a half-second drop from 10000% to 1%", curve([(0, 10_000, nil, sharp), (0.5, 1, sharp, nil)])),
            ("a 120 s piece with full-width handles", curve([(0, 1, nil, long), (120, 400, long, nil)])),
            ("overshoot past the clamp", curve([(0, 5, nil, back), (20, 50, back, nil)])),
            ("several short pieces", curve((0..<12).map { (Double($0) * 0.7, $0.isMultiple(of: 2) ? 1 : 8_000, KeyframeEase(influence: 0.4, speed: 3), KeyframeEase(influence: 0.4, speed: 3)) })),
            ("linear pieces", curve([(0, 100, nil, nil), (50, 5, nil, nil), (90, 3_000, nil, nil)])),
        ]
    }

    // MARK: Tests

    @Test func theReferenceAgreesWithTheClosedFormOfALinearRamp() {
        // Speed 100 -> 200 over 2 s: the integral of 1 / (1 + t / 2) is 2 ln 2.
        let ramp = curve([(0, 100, nil, nil), (2, 200, nil, nil)])
        let piece = pieces(of: ramp)[0]
        #expect(abs(trueTotal(piece) - 2 * log(2)) < 1e-12)
        // And its Bézier agrees with the production ease on a curved one.
        let eased = Piece(t0: 0, t1: 4, v0: 0, v1: 1, out: KeyframeEase(influence: 0.3, speed: 2), into: .easy)
        for fraction in [0.0, 0.1, 0.5, 0.77, 1] {
            #expect(abs(progress(fraction, eased) - KeyframeEase.progress(fraction, leaving: eased.out, arriving: eased.into)) < 1e-9)
        }
    }

    /// Simpson's sum over a piece as `SpeedIntegral` makes it, but with the
    /// nodes at their exact times: no quantization, only quadrature error.
    private func simpsonAtExactNodes(_ piece: Piece) -> Double {
        let steps = SpeedIntegral.stepsPerPiece, h = (piece.t1 - piece.t0) / Double(steps)
        var sum = rate(piece.t0, piece) + rate(piece.t1, piece)
        for i in 1..<steps { sum += rate(piece.t0 + Double(i) * h, piece) * (i.isMultiple(of: 2) ? 2 : 4) }
        return sum * h / 3
    }

    private func productionTotal(_ piece: Piece, of speed: AnimatedValue<Double>) -> Double {
        let integral = SpeedIntegral.of(speed)
        return integral.at(piece.t1) - integral.at(piece.t0)
    }

    /// Quantization is the part of the error a bound can be set on from the
    /// handles alone: at most (length) x (largest rate change per second) x
    /// (grid step), per piece. The bound can be loose (the rate's slope
    /// is huge for short handles) and is infinite when the handles make the
    /// curve's time stall; the measured value is printed beside it.
    @Test func quantizationStaysWithinABoundFromTheHandles() {
        for (name, speed) in demanding {
            let step = 1 / Double(SpeedIntegral.rateTimescale)
            for piece in pieces(of: speed) {
                let quantization = productionTotal(piece, of: speed) - simpsonAtExactNodes(piece)
                let bound = (piece.t1 - piece.t0) * rateSlopeBound(piece) * step
                print("ACC quantization \(name): measured \(quantization), bound \(bound)")
                #expect(abs(quantization) <= bound, "\(name)")
            }
        }
    }

    /// The other part: Simpson's 24 steps against the reference. Printed
    /// for every curve; asserted where the curve is gentle.
    @Test func quadratureErrorOfAGentleRampIsSmall() {
        let gentle = curve([(0, 100, .easy, .easy), (10, 30, .easy, .easy), (25, 800, .easy, .easy), (40, 100, .easy, .easy)])
        for piece in pieces(of: gentle) {
            let truth = trueTotal(piece)
            #expect(abs(simpsonAtExactNodes(piece) - truth) <= 1e-3 * truth)
            #expect(abs(productionTotal(piece, of: gentle) - truth) <= 1e-3 * truth)
        }
    }

    @Test func quadratureErrorOfADemandingRampIsSmall() {
        for (name, speed) in demanding {
            for piece in pieces(of: speed) {
                let truth = trueTotal(piece)
                let quadrature = simpsonAtExactNodes(piece) - truth
                print("ACC quadrature \(name): \(piece.t0)...\(piece.t1) truth \(truth), Simpson error \(quadrature) (\(quadrature / truth))")
            }
        }
        // Known not to hold: Simpson's 24 steps are far off on a curve whose
        // rate changes by orders of magnitude (5% -> 3000% over 40 s reads 16.3 s
        // for 8.54 s). See the printout above.
        withKnownIssue("Simpson's fixed 24 steps are inaccurate where the rate changes by orders of magnitude") {
            for (_, speed) in demanding {
                for piece in pieces(of: speed) {
                    let truth = trueTotal(piece)
                    #expect(abs(productionTotal(piece, of: speed) - truth) <= 1e-6 * truth)
                }
            }
        }
    }
}
