import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// How far `SpeedIntegral` is from the true integral of 100 / speed,
/// against a reference that shares none of its machinery: its own Bézier,
/// read at exact `Double` times, integrated by adaptive Gauss-Kronrod with a
/// tighter tolerance and a fixed fine partition (128 spans, 12 halvings;
/// a first try with 32 and 8 was off by up to 3e-7 on the sharp curves, which
/// `theReferenceHasConverged` caught). The budget, from `SpeedIntegral`'s doc: `at(s)` within
/// `(pieces before s + 2) * pieceTolerance` plus 1e-12 of the value, and
/// the inverse within `timeTolerance` of the target.
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
    private func reference(_ f: (Double) -> Double, _ a: Double, _ b: Double, tolerance: Double = 1e-12, depth: Int = 0, maxDepth: Int = 8) -> Double {
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
        if abs(k - g) <= tolerance || depth >= maxDepth { return k }
        return reference(f, a, centre, tolerance: tolerance / 2, depth: depth + 1, maxDepth: maxDepth) + reference(f, centre, b, tolerance: tolerance / 2, depth: depth + 1, maxDepth: maxDepth)
    }

    /// The true integral over `a...b` within a piece, over a fixed partition
    /// into `cuts` spans (which puts the clamp's kinks near a span's edge)
    /// each integrated adaptively.
    private func trueIntegral(_ piece: Piece, from a: Double, to b: Double, cuts: Int = 128, maxDepth: Int = 12, crossings: [Double]? = nil) -> Double {
        guard b > a else { return 0 }
        var points = (0...cuts).map { a + (b - a) * Double($0) / Double(cuts) }
        points += (crossings ?? clampCrossings(piece)).filter { $0 > a && $0 < b }
        points.sort()
        return zip(points, points.dropFirst()).reduce(0) { $0 + reference({ rate($0, piece) }, $1.0, $1.1, maxDepth: maxDepth) }
    }

    /// Where the piece's speed meets the clamp's limits, found by sampling the
    /// unclamped value for a crossing and halving to Double's precision, so
    /// that the rate's kinks fall on the edge of a span, where a quadrature
    /// rule is not fooled by them.
    private func clampCrossings(_ piece: Piece) -> [Double] {
        func value(_ time: Double) -> Double { piece.v0 + (piece.v1 - piece.v0) * progress((time - piece.t0) / (piece.t1 - piece.t0), piece) }
        var crossings = [Double]()
        let samples = 4096
        for limit in [ClipTime.speedRange.lowerBound, ClipTime.speedRange.upperBound] {
            for index in 0..<samples {
                var low = piece.t0 + (piece.t1 - piece.t0) * Double(index) / Double(samples)
                var high = piece.t0 + (piece.t1 - piece.t0) * Double(index + 1) / Double(samples)
                let below = value(low) < limit
                guard below != (value(high) < limit) else { continue }
                for _ in 0..<60 {
                    let middle = (low + high) / 2
                    if (value(middle) < limit) == below { low = middle } else { high = middle }
                }
                crossings.append((low + high) / 2)
            }
        }
        return crossings
    }

    private func trueTotal(_ piece: Piece) -> Double { trueIntegral(piece, from: piece.t0, to: piece.t1) }

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

    private let tolerance = SpeedIntegral.pieceTolerance

    /// What `at` may be off by with `count` pieces' worth of cells summed (a
    /// query inside a piece sums its earlier pieces, that piece's cells
    /// before the query's, and a partial cell: `pieces before + 2`), for a
    /// true value `truth`.
    private func budget(pieces count: Int, truth: Double) -> Double {
        Double(count) * tolerance + 1e-12 * abs(truth)
    }

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

    /// The reference has to be far inside the budget to be a judge: it must
    /// not move when its partition and depth are made finer.
    @Test func theReferenceHasConverged() {
        for (name, speed) in demanding {
            for piece in pieces(of: speed) {
                let coarse = trueTotal(piece)  // the reference as the other tests use it
                let fine = trueIntegral(piece, from: piece.t0, to: piece.t1, cuts: 512, maxDepth: 18)
                #expect(abs(coarse - fine) <= 1e-10 + 1e-12 * abs(fine), "\(name): \(coarse) vs \(fine)")
            }
        }
    }

    @Test func theEasedCurveAtExactSecondsIsTheCurveAtAMatchingCMTime() {
        for (name, speed) in demanding {
            for piece in pieces(of: speed) {
                for fraction in [0.0, 0.25, 0.5, 0.9, 1] {
                    // A time on the 600 grid the keyframes are on.
                    let seconds = (piece.t0 + (piece.t1 - piece.t0) * fraction * 600).rounded() / 600
                    let time = CMTime(seconds: seconds, preferredTimescale: 600)
                    #expect(abs(speed.value(atSeconds: time.seconds) - speed.value(at: time)) <= 1e-9 * max(1, abs(speed.value(at: time))), Comment(rawValue: name))
                }
            }
        }
    }

    @Test func aWholePieceIsWithinTheBudgetOfTheReference() {
        for (name, speed) in demanding {
            let integral = SpeedIntegral.of(speed)
            var truth = 0.0
            for (index, piece) in pieces(of: speed).enumerated() {
                truth += trueTotal(piece)
                let got = integral.at(piece.t1)
                #expect(abs(got - truth) <= budget(pieces: index + 1, truth: truth), "\(name) piece \(index): \(got) vs \(truth)")
            }
        }
    }

    /// Queries inside a cell: the cell's edges (and just either side),
    /// the middle of each cell, and arbitrary points, against the reference
    /// integrated from the piece's start.
    @Test func partialCellsAreWithinTheBudgetOfTheReference() {
        for (name, speed) in demanding {
            let integral = SpeedIntegral.of(speed)
            var before = 0.0
            for (index, piece) in pieces(of: speed).enumerated() {
                var queries = [piece.t0 + 1e-9, piece.t1 - 1e-9]
                for fraction in stride(from: 0.013, to: 1, by: 0.0971) { queries.append(piece.t0 + (piece.t1 - piece.t0) * fraction) }
                let edges = integral.cellEdges.filter { $0 > piece.t0 && $0 < piece.t1 }
                for edge in edges { queries += [edge - 1e-7, edge, edge + 1e-7] }
                for (a, b) in zip(edges, edges.dropFirst()) { queries.append((a + b) / 2) }
                // One pass over the sorted queries, each span of the piece
                // integrated once (with spans cut as finely as the whole
                // piece is), instead of every query from the piece's start.
                let crossings = clampCrossings(piece)
                var truth = before, last = piece.t0
                for query in queries.filter({ $0 > piece.t0 && $0 < piece.t1 }).sorted() {
                    let cuts = max(2, Int(128 * (query - last) / (piece.t1 - piece.t0)))
                    truth += trueIntegral(piece, from: last, to: query, cuts: cuts, crossings: crossings)
                    last = query
                    let got = integral.at(query)
                    #expect(abs(got - truth) <= budget(pieces: index + 2, truth: truth), "\(name) at \(query): \(got) vs \(truth)")
                }
                before += trueTotal(piece)
            }
        }
    }

    @Test func theIntegralOnlyRises() {
        for (name, speed) in demanding {
            let integral = SpeedIntegral.of(speed)
            let first = pieces(of: speed).first!.t0, last = pieces(of: speed).last!.t1
            var previous = integral.at(first - 1)
            for index in 0...3000 {
                let value = integral.at(first - 1 + (last - first + 2) * Double(index) / 3000)
                #expect(value >= previous - 2 * tolerance, "\(name) at step \(index)")
                previous = value
            }
        }
    }

    @Test func theInverseLandsOnTheTargetAndAgreesWithTheReference() {
        for (name, speed) in demanding {
            let integral = SpeedIntegral.of(speed)
            let all = pieces(of: speed)
            let total = integral.at(all.last!.t1)
            for fraction in [-0.1, 0, 1e-6, 0.01, 0.2, 0.5, 0.77, 0.999, 1, 1.2] {
                let target = total * fraction
                let source = integral.source(atIntegral: target)
                // On `at`'s own curve, to the inverse's tolerance (and `at`'s
                // own jitter where the adaptive rule changes its mind).
                #expect(abs(integral.at(source) - target) <= SpeedIntegral.timeTolerance + 2 * tolerance, "\(name) \(fraction)")
                // And on the true curve, to the budget.
                var truth = 0.0
                if target <= 0 || target >= total { continue }
                for piece in all {
                    if source <= piece.t0 { break }
                    truth += trueIntegral(piece, from: piece.t0, to: min(source, piece.t1))
                }
                #expect(abs(truth - target) <= budget(pieces: all.count + 1, truth: truth) + SpeedIntegral.timeTolerance, "\(name) \(fraction): \(truth) vs \(target)")
            }
        }
    }

    @Test func theInverseOfEachCellEdgeIsTheEdge() {
        for (name, speed) in demanding {
            let integral = SpeedIntegral.of(speed)
            for edge in integral.cellEdges {
                let back = integral.source(atIntegral: integral.at(edge))
                // Equal integrals mean equal points to within the time the
                // tolerance is worth at the slowest rate there.
                #expect(abs(integral.at(back) - integral.at(edge)) <= SpeedIntegral.timeTolerance + 2 * tolerance, "\(name) at \(edge)")
            }
        }
    }

    // MARK: Cost

    /// The fixed 24-step Simpson sum this replaced, with the rate read at
    /// times cut to a 1e-9 grid: the cost to beat, and the error to show.
    private struct Simpson {
        let speed: AnimatedValue<Double>
        let times: [Double]
        var totals = [0.0]

        init(_ speed: AnimatedValue<Double>) {
            self.speed = speed
            times = speed.keyframes.map(\.time.seconds)
            for index in times.indices.dropFirst() { totals.append(totals[index - 1] + Self.simpson(speed, times[index - 1], times[index])) }
        }

        static func rate(_ speed: AnimatedValue<Double>, _ seconds: Double) -> Double {
            100 / min(max(speed.value(at: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)), 1), 10_000)
        }

        static func simpson(_ speed: AnimatedValue<Double>, _ low: Double, _ high: Double) -> Double {
            guard high > low else { return 0 }
            let h = (high - low) / 24
            var sum = rate(speed, low) + rate(speed, high)
            for i in 1..<24 { sum += rate(speed, low + Double(i) * h) * (i.isMultiple(of: 2) ? 2 : 4) }
            return sum * h / 3
        }

        func at(_ seconds: Double) -> Double {
            var index = 0
            while index + 1 < times.count - 1, times[index + 1] <= seconds { index += 1 }
            return totals[index] + Self.simpson(speed, times[index], seconds)
        }
    }

    /// Run with `swift test -c release -Xswiftc -enable-testing --filter
    /// rebuildsAndLookups` to read the release numbers; in a debug build the
    /// ratios hold but the times are several times longer.
    @Test func rebuildsAndLookupsCostLittle() {
        func milliseconds(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            body()
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) / 1e15
        }
        var sink = 0.0
        for (name, speed) in demanding {
            let rebuilds = 20
            let rebuildNew = milliseconds { for _ in 0..<rebuilds { sink += SpeedIntegral(speed).at(1) } } / Double(rebuilds)
            let rebuildOld = milliseconds { for _ in 0..<rebuilds { sink += Simpson(speed).at(1) } } / Double(rebuilds)
            let integral = SpeedIntegral(speed)
            let old = Simpson(speed)
            let first = pieces(of: speed).first!.t0, last = pieces(of: speed).last!.t1
            let points = (0..<2000).map { first + (last - first) * (Double($0) + 0.5) / 2000 }
            let total = integral.at(last)
            let targets = (0..<2000).map { total * (Double($0) + 0.5) / 2000 }
            let atNew = milliseconds { for x in points { sink += integral.at(x) } } / 2000 * 1000
            let atOld = milliseconds { for x in points { sink += old.at(x) } } / 2000 * 1000
            let inverse = milliseconds { for t in targets { sink += integral.source(atIntegral: t) } } / 2000 * 1000
            print(String(format: "BENCH %@: cells %d (keyframes %d); rebuild %.3f ms (Simpson %.3f); at %.2f us (Simpson %.2f); inverse %.2f us",
                         name, integral.cellEdges.count, speed.keyframes.count, rebuildNew, rebuildOld, atNew, atOld, inverse))
        }
        #expect(sink.isFinite)
    }
}
