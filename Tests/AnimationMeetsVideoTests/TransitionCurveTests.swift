import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct TransitionCurveTests {
    @Test func linearRunsEvenly() {
        let curve = TransitionCurve.linear
        for time in [0.0, 0.25, 0.5, 0.9, 1] {
            #expect(abs(curve.value(at: time) - time) < 1e-6)
        }
    }

    @Test func presetsEaseWhereTheirNamesSay() {
        let easeOut = TransitionCurve(preset: .easeOut)
        let easeIn = TransitionCurve(preset: .easeIn)
        let easy = TransitionCurve(preset: .easyEase)
        // Easing out starts slowly; easing in arrives slowly.
        #expect(easeOut.value(at: 0.1) < 0.1)
        #expect(easeIn.value(at: 0.9) > 0.9)
        #expect(easy.value(at: 0.1) < 0.1 && easy.value(at: 0.9) > 0.9)
        #expect(abs(easy.value(at: 0.5) - 0.5) < 1e-6)
        #expect(easy.value(at: 0) == 0 && easy.value(at: 1) == 1)
        #expect(easy.preset == .easyEase)
        #expect(TransitionCurve.linear.preset == .linear)
    }

    @Test func addingAPointKeepsTheShape() throws {
        var curve = TransitionCurve(preset: .easyEase)
        let samples = stride(from: 0.0, through: 1, by: 0.05).map { curve.value(at: $0) }
        let inserted = curve.insertPoint(atTime: 0.3)
        let index = try #require(inserted)
        #expect(index == 1)
        #expect(curve.points.count == 3)
        #expect(curve.preset == nil)
        for (time, value) in zip(stride(from: 0.0, through: 1, by: 0.05), samples) {
            #expect(abs(curve.value(at: time) - value) < 1e-4)
        }
    }

    @Test func aPointOnAStraightLineIsACorner() throws {
        var curve = TransitionCurve.linear
        let inserted = curve.insertPoint(atTime: 0.5)
        let index = try #require(inserted)
        #expect(curve.points[index].inHandle == nil && curve.points[index].outHandle == nil)
        curve.movePoint(index, to: CGPoint(x: 0.5, y: 0.9))
        #expect(abs(curve.value(at: 0.5) - 0.9) < 1e-6)
        #expect(abs(curve.value(at: 0.25) - 0.45) < 1e-6)
    }

    @Test func pointsStayBetweenTheirNeighborsAndTheEndsStayPut() throws {
        var curve = TransitionCurve.linear
        let inserted = curve.insertPoint(atTime: 0.5)
        let index = try #require(inserted)
        curve.movePoint(index, to: CGPoint(x: 2, y: -1))
        #expect(curve.points[index].time < 1 && curve.points[index].value == 0)
        curve.movePoint(0, to: CGPoint(x: 0.5, y: 0.5))
        #expect(curve.points[0].location == .zero)
    }

    @Test func handlesCanNotTurnTheCurveBack() {
        var curve = TransitionCurve.linear
        curve.setHandle(.outgoing, of: 0, to: CGVector(dx: -0.5, dy: 0.3))
        #expect(curve.points[0].outHandle == CGVector(dx: 0, dy: 0.3))
        curve.setHandle(.outgoing, of: 0, to: CGVector(dx: 3, dy: 0))
        #expect(curve.points[0].outHandle?.dx == 1)
        // The first point has no way in.
        curve.setHandle(.incoming, of: 0, to: CGVector(dx: -0.2, dy: 0))
        #expect(curve.points[0].inHandle == nil)
    }

    @Test func optionClickTogglesCornersAndStraightensSegments() throws {
        var curve = TransitionCurve(preset: .easyEase)
        curve.toggleCorner(0)
        #expect(curve.points[0].outHandle == nil)
        curve.toggleCorner(0)
        #expect(curve.points[0].outHandle == CGVector(dx: TransitionCurve.influence, dy: 0))

        curve.straightenSegment(0)
        #expect(curve == .linear)

        let inserted = curve.insertPoint(atTime: 0.5)
        let index = try #require(inserted)
        curve.toggleCorner(index)
        let handle = try #require(curve.points[index].outHandle)
        // Smooth handles follow the line through the neighbors.
        #expect(abs(handle.dy / handle.dx - 1) < 1e-9)
        curve.removePoint(index)
        #expect(curve.points.count == 2)
    }

    @Test func badSavedPointsAreRefused() {
        #expect(TransitionCurve(points: [.init(time: 0, value: 0), .init(time: 1, value: 0.5)]) == nil)
        #expect(TransitionCurve(points: [.init(time: 0, value: 0), .init(time: 0, value: 0.5), .init(time: 1, value: 1)]) == nil)
    }

    @Test func transitionsFollowTheirCurve() {
        var clip = TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        let curve = TransitionCurve(preset: .easeOut)
        clip.transitionIn = ClipTransition(kind: .crossDissolve, duration: CMTime(value: 2, timescale: 1), curve: curve)
        clip.transitionOut = ClipTransition(kind: .crossDissolve, duration: CMTime(value: 2, timescale: 1), curve: curve)
        let edges = EdgeTransitions(clip: clip, frameSize: CGSize(width: 10, height: 10))!
        let quarter = curve.value(at: 0.25)
        #expect(abs(edges.effect(at: CMTime(value: 1, timescale: 2)).opacity - quarter) < 1e-6)
        // A way out plays the same curve, hiding the clip.
        #expect(abs(edges.effect(at: CMTime(value: 5, timescale: 2)).opacity - (1 - quarter)) < 1e-6)
    }
}
