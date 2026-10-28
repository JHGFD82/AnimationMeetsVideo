import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ToneCurveTests {
    private func curve(_ points: [(Double, Double)]) -> ToneCurve {
        ToneCurve(points: points.map { ToneCurve.Point(x: $0.0, y: $0.1) })
    }

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    @Test func theIdentityChangesNoTone() {
        #expect(ToneCurve.identity.isIdentity)
        #expect(ToneCurve.identityValues == [0, 0, 1, 1])
        for x in stride(from: 0.0, through: 1, by: 0.1) { #expect(abs(ToneCurve.identity.value(at: x) - x) < 1e-12) }
        // Points along the diagonal change nothing either.
        #expect(curve([(0, 0), (0.4, 0.4), (1, 1)]).isIdentity)
        #expect(!curve([(0, 0), (0.4, 0.5), (1, 1)]).isIdentity)
    }

    @Test func itPassesThroughEveryPointWithoutOvershooting() {
        let s = curve([(0, 0), (0.25, 0.15), (0.5, 0.5), (0.75, 0.85), (1, 1)])
        for point in s.points { #expect(abs(s.value(at: point.x) - point.y) < 1e-12) }
        // Monotone pieces stay within their ends, so a rising curve keeps
        // the tones in order.
        let xs = (0...1000).map { Double($0) / 1000 }
        let ys = s.sample(xs)
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 })
        // A sharp step doesn't ring past its plateaus.
        let step = curve([(0, 0), (0.45, 0.1), (0.55, 0.9), (1, 1)])
        #expect(step.sample(xs).allSatisfy { (-1e-12...(1 + 1e-12)).contains($0) })
        #expect(step.sample(xs.filter { $0 <= 0.45 }).allSatisfy { $0 <= 0.1 + 1e-12 })
    }

    @Test func itHoldsPastItsEndsAndCarriesOnPastWhite() {
        let lifted = curve([(0.1, 0.2), (0.8, 0.9)])
        #expect(lifted.value(at: 0) == 0.2)
        #expect(lifted.value(at: 0.95) == 0.9)
        // Ending before white it is flat there, and stays so past it.
        #expect(lifted.slopeAtWhite == 0)
        #expect(lifted.value(at: 1.5) == 0.9)
        // Ending at white, HDR tones carry on along its last slope.
        let bright = curve([(0, 0), (0.5, 0.75), (1, 1)])
        #expect(bright.slopeAtWhite > 0)
        #expect(abs(bright.value(at: 1.5) - (1 + 0.5 * bright.slopeAtWhite)) < 1e-12)
        #expect(abs(ToneCurve.identity.value(at: 2) - 2) < 1e-12)
    }

    @Test func pointsAreReadInOrderAndKeptApart() {
        #expect(curve([(1, 1), (0, 0), (0.5, 0.7)]).values == [0, 0, 0.5, 0.7, 1, 1])
        #expect(curve([(0, 0), (0.505, 0.6), (0.5, 0.5), (1, 1)]).points.count == 3)
        #expect(curve([(-0.2, -1), (1.4, 2)]).values == [0, 0, 1, 1])
        #expect(curve([(0.5, 0.5)]) == .identity)
        #expect(curve([(0, .nan), (1, 1)]) == .identity)
        // Saved numbers are read in pairs, an odd one left over dropped.
        #expect(ToneCurve(values: [0, 0.1, 1, 0.9, 0.5]).values == [0, 0.1, 1, 0.9])
    }

    @Test func editingKeepsTheShapeAndTheOrder() {
        let s = curve([(0, 0), (0.5, 0.6), (1, 1)])
        // A point moves no further than its neighbors allow.
        let pushed = s.moving(1, toX: 2, y: 2).points[1]
        #expect(abs(pushed.x - 0.99) < 1e-12 && pushed.y == 1)
        let held = s.moving(0, toX: 0.7, y: 0.1).points[0]
        #expect(abs(held.x - 0.49) < 1e-12 && held.y == 0.1)
        // One added lands on the curve, which barely changes.
        let added = s.inserting(atX: 0.25)
        #expect(added.points.count == 4)
        #expect(abs(added.points[1].y - s.value(at: 0.25)) < 1e-12)
        #expect(s.inserting(atX: 0.505) == s)
        // Two are always left.
        #expect(s.removing(1).points.count == 2)
        #expect(ToneCurve.identity.removing(0) == .identity)
        #expect(abs(s.widestGapMiddle - 0.25) < 1e-12)
    }

    @Test func aTableSamplesFromBlackToWhite() {
        let s = curve([(0, 0.1), (1, 0.9)])
        let table = s.table(count: 5)
        #expect(table.count == 5)
        #expect(abs(table[0] - 0.1) < 1e-12 && abs(table[2] - 0.5) < 1e-12 && abs(table[4] - 0.9) < 1e-12)
    }

    @Test func aCurveControlsPointsChangeAtEveryKeyframe() throws {
        let kind = try #require(EffectKind(rawValue: "curves"))
        var control = try #require(Effect(kind: kind).controls.first { $0.kind.isCurve })
        #expect(control.curve(at: .zero) == .identity)
        control.setCurve(curve([(0, 0), (1, 0.8)]), at: .zero)
        control.number.setAnimated(true, at: time(0))
        control.setCurve(curve([(0, 0.2), (1, 1)]), at: time(2))
        // Halfway the curves blend point by point.
        #expect(control.curve(at: time(1)).values == [0, 0.1, 1, 0.9])

        // A point added lands on each keyframe's own curve there.
        #expect(control.insertCurvePoint(atX: 0.5, at: time(1)) == 1)
        #expect(control.number.keyframes.map { $0.value.values.count } == [6, 6])
        #expect(control.number.keyframes[0].value.values == [0, 0, 0.5, 0.4, 1, 0.8])
        #expect(control.number.keyframes[1].value.values == [0, 0.2, 0.5, 0.6, 1, 1])
        #expect(control.insertCurvePoint(atX: 0.505, at: time(1)) == nil)

        // Moving it at one keyframe leaves the other.
        control.setCurve(control.curve(at: time(2)).moving(1, toX: 0.5, y: 0.9), at: time(2))
        #expect(control.number.keyframes[0].value.values[3] == 0.4)
        #expect(control.number.keyframes[1].value.values[3] == 0.9)

        control.removeCurvePoint(1)
        #expect(control.number.keyframes.map { $0.value.values.count } == [4, 4])
        control.removeCurvePoint(0)
        #expect(control.number.keyframes.map { $0.value.values.count } == [4, 4])
    }

    @Test func curveControlsAreNotNumbersToGraphOrKeyframeFrom() throws {
        let kind = try #require(EffectKind(rawValue: "curves"))
        let effect = Effect(kind: kind)
        let curves = effect.controls.filter(\.kind.isCurve)
        #expect(curves.map(\.kind.name) == ["RGB", "Red", "Green", "Blue"])
        #expect(curves.map(\.kind.curveTint) == [.white, .red, .green, .blue])
        #expect(curves.allSatisfy { $0.kind.componentNames.isEmpty })
        // A set curve reads as set, not as its numbers.
        var changed = effect
        changed.changeControl(curves[1].kind) { $0.setCurve(curve([(0, 0.1), (1, 1)]), at: .zero) }
        #expect(changed.summary.settings == ["Red set"])
    }
}
