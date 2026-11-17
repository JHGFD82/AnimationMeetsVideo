import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Free paths drawn with the pen (docs/pen-tool.md, "A path").
@Suite struct FreePathTests {
    private typealias Vertex = FreePath.Vertex

    /// A square 100 across about the middle, corners only.
    private var square: FreePath {
        FreePath(vertices: [
            Vertex(CGPoint(x: -50, y: -50)), Vertex(CGPoint(x: 50, y: -50)),
            Vertex(CGPoint(x: 50, y: 50)), Vertex(CGPoint(x: -50, y: 50)),
        ], closed: true)
    }

    /// An S of two curves through three points.
    private var curve: FreePath {
        FreePath(vertices: [
            Vertex(CGPoint(x: 0, y: 0), out: CGVector(dx: 40, dy: -60)),
            Vertex(CGPoint(x: 100, y: 0), in: CGVector(dx: -30, dy: -20), out: CGVector(dx: 30, dy: 20)),
            Vertex(CGPoint(x: 200, y: 0), in: CGVector(dx: -40, dy: 60)),
        ])
    }

    @Test func numbersToPathAndBack() {
        let path = curve
        #expect(path.values.count == 18)
        #expect(FreePath(values: path.values, closed: false) == path)
        // Read leniently: what doesn't make a whole vertex is dropped.
        #expect(FreePath(values: path.values + [1, 2, 3], closed: false) == path)
        #expect(FreePath(values: [1, 2, 3, 4, 5], closed: true).vertices.isEmpty)
    }

    @Test func cornersAreLinesAndTangentsAreCurves() {
        var lines = 0, curves = 0, closes = 0
        square.cgPath().applyWithBlock { element in
            switch element.pointee.type {
            case .addLineToPoint: lines += 1
            case .addCurveToPoint: curves += 1
            case .closeSubpath: closes += 1
            default: break
            }
        }
        // Four sides, the last back to the first, then closed.
        #expect(lines == 4 && curves == 0 && closes == 1)
        lines = 0
        curves = 0
        closes = 0
        curve.cgPath().applyWithBlock { element in
            switch element.pointee.type {
            case .addLineToPoint: lines += 1
            case .addCurveToPoint: curves += 1
            case .closeSubpath: closes += 1
            default: break
            }
        }
        #expect(lines == 0 && curves == 2 && closes == 0)
        // Offset to where it is drawn.
        #expect(square.cgPath(origin: CGPoint(x: 64, y: 36)).boundingBox == CGRect(x: 14, y: -14, width: 100, height: 100))
    }

    @Test func aSplitKeepsTheShapeAtEverySample() {
        let before = curve
        var split = before
        let at = split.split(segment: 0, at: 0.3)
        #expect(at == 1)
        #expect(split.vertices.count == 4)
        // The first stretch of the original, sampled, lies on the two
        // stretches it became.
        for step in 0...20 {
            let t = Double(step) / 20
            let point = before.point(onSegment: 0, at: t)
            let nearest = split.nearest(to: point)
            #expect((nearest?.distance ?? .infinity) < 0.01, "at \(t)")
        }
        #expect(split.kind(of: 1) == .ease)
        // A straight stretch gets a linear point on it.
        var box = square
        box.split(segment: 0, at: 0.5)
        #expect(box.vertices[1].point == CGPoint(x: 0, y: -50))
        #expect(box.kind(of: 1) == .linear)
    }

    @Test func removingAPointKeepsItsNeighboursTangents() {
        var path = curve
        path.remove(1)
        #expect(path.vertices.count == 2)
        #expect(path.vertices[0].outTangent == CGVector(dx: 40, dy: -60))
        #expect(path.vertices[1].inTangent == CGVector(dx: -40, dy: 60))
        // Down to one point it can't be closed.
        var two = FreePath(vertices: [Vertex(.zero), Vertex(CGPoint(x: 1, y: 1))], closed: true)
        two.remove(0)
        #expect(!two.closed)
    }

    @Test func aPointsKindIsReadFromItsTangents() {
        #expect(square.kind(of: 0) == .linear)
        #expect(curve.kind(of: 1) == .ease)
        // An end with its one tangent is ease.
        #expect(curve.kind(of: 0) == .ease)
        var broken = curve
        broken.vertices[1].outTangent = CGVector(dx: 30, dy: -20)
        #expect(broken.kind(of: 1) == .broken)
        // A middle point with one tangent is broken.
        broken.vertices[1].inTangent = .zero
        #expect(broken.kind(of: 1) == .broken)
    }

    @Test func makeEaseWorksTangentsOut() throws {
        // Parallel to the line between its neighbours, a third of the way
        // to each.
        let path = FreePath(vertices: [Vertex(CGPoint(x: 0, y: 0)), Vertex(CGPoint(x: 60, y: -30)), Vertex(CGPoint(x: 90, y: 0))])
        let tangents = try #require(path.easeTangents(for: 1))
        #expect(FreePath.inLine(tangents.in, tangents.out))
        #expect(abs(tangents.in.dy) < 1e-9 && abs(tangents.out.dy) < 1e-9)
        #expect(abs(tangents.in.length - hypot(60, 30) / 3) < 1e-9)
        #expect(abs(tangents.out.length - hypot(30, 30) / 3) < 1e-9)
        // An end gets one, toward its neighbour.
        let end = try #require(path.easeTangents(for: 0))
        #expect(end.in == .zero)
        #expect(end.out == CGVector(dx: 20, dy: -10))
    }

    @Test func bendingAStretchPassesItThroughThePoint() {
        var path = square
        let target = CGPoint(x: 10, y: -80)
        path.bend(segment: 0, at: 0.5, through: target)
        let reached = path.point(onSegment: 0, at: 0.5)
        #expect(abs(reached.x - target.x) < 1e-9 && abs(reached.y - target.y) < 1e-9)
        #expect(!path.isStraight(0))
        // The other stretches are as they were.
        #expect(path.isStraight(1) && path.isStraight(2) && path.isStraight(3))
    }

    @Test func keyframesBlendWithEqualCountsAndHoldWithUnequal() {
        var control = EffectControl(kind: .path)
        let start = CMTime(value: 0, timescale: 24), end = CMTime(value: 24, timescale: 24)
        let half = CMTime(value: 12, timescale: 24)
        let one = FreePath(vertices: [Vertex(.zero), Vertex(CGPoint(x: 100, y: 0))])
        var other = one
        other.vertices[1].point = CGPoint(x: 200, y: 0)
        control.number.setAnimated(true, at: start)
        control.setPath(one, at: start)
        control.setPath(other, at: end)
        #expect(control.freePath(at: half).vertices[1].point.x == 150)
        // A third point at the end: the earlier holds until it.
        var three = other
        three.vertices.append(Vertex(CGPoint(x: 300, y: 0)))
        control.setPath(three, at: end)
        #expect(control.freePath(at: half) == one)
        #expect(control.freePath(at: end) == three)
    }

    @Test func addingAPointActsOnEveryKeyframe() {
        var control = EffectControl(kind: .path)
        let start = CMTime(value: 0, timescale: 24), end = CMTime(value: 24, timescale: 24)
        control.number.setAnimated(true, at: start)
        control.setPath(square, at: start)
        var bigger = square
        for index in bigger.vertices.indices { bigger.vertices[index].point.x *= 2 }
        control.setPath(bigger, at: end)
        control.mapPath { $0.split(segment: 0, at: 0.5) }
        #expect(control.number.keyframes.allSatisfy { $0.value.values.count == 5 * FreePath.numbersPerVertex })
        #expect(control.freePath(at: end).vertices[1].point == CGPoint(x: 0, y: -50))
        #expect(control.closed)
    }

    @Test func pathMaskIsNoOpUntilClosed() {
        var mask = Effect(kind: .pathMask)
        #expect(mask.isNoOp)
        mask.changeControl(.path) { $0.setPath(FreePath(vertices: square.vertices, closed: false), at: .zero) }
        #expect(mask.isNoOp)
        mask.changeControl(.path) { $0.closed = true }
        #expect(!mask.isNoOp)
        #expect(!EffectKind.pathMask.isLook)
        #expect(EffectKind.all.contains(.pathMask) && EffectKind.generators.contains(.path))
    }

    @Test func convertToPathKeepsTheShapeAndItsPaint() throws {
        var box = Effect(kind: .rectangle)
        box.changeControl(.shapeSize) { $0.number = AnimatedValue(ComponentValue(values: [200, 100])) }
        box.changeControl(.shapePosition) { $0.number = AnimatedValue(ComponentValue(values: [30, -10])) }
        box.changeControl(.fill) { $0.number = AnimatedValue(ComponentValue(values: [1, 0, 0, 1])) }
        let path = try #require(box.convertedToPath(at: .zero))
        #expect(path.kind == .path)
        let outline = try #require(path.control(.path)).freePath(at: .zero)
        #expect(outline.closed && outline.vertices.count == 4)
        #expect(outline.vertices.allSatisfy { path.control(.path) != nil && $0.inTangent == .zero && $0.outTangent == .zero })
        #expect(outline.cgPath().boundingBox == CGRect(x: -100, y: -50, width: 200, height: 100))
        #expect(path.control(.shapePosition)?.values(at: .zero) == [30, -10])
        #expect(path.control(.fill)?.values(at: .zero) == [1, 0, 0, 1])
        // Drawn where it was.
        let before = try #require(ShapeStep(box, at: .zero, center: CGPoint(x: 960, y: 540))).path.boundingBox
        let after = try #require(ShapeStep(path, at: .zero, center: CGPoint(x: 960, y: 540))).path.boundingBox
        #expect(abs(before.minX - after.minX) < 0.01 && abs(before.maxY - after.maxY) < 0.01)

        // An ellipse: four curves, every point ease.
        let ellipse = try #require(Effect(kind: .ellipse).convertedToPath(at: .zero))
        let round = try #require(ellipse.control(.path)).freePath(at: .zero)
        #expect(round.closed && round.vertices.count == 4)
        #expect(round.vertices.indices.allSatisfy { round.kind(of: $0) == .ease })
        #expect(Effect(kind: .text).convertedToPath(at: .zero) == nil)
    }
}
