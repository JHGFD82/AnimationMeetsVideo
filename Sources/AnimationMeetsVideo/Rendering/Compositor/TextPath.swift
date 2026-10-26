import CoreGraphics
import Foundation

/// An outline text follows (see docs/graphic-layers.md, "Text on a
/// path"): a shape's first subpath, flattened into straight pieces, in the
/// frame's pixels, and how far along it each point is.
struct TextPath: Equatable, Sendable {
    var points: [CGPoint]
    var closed: Bool

    /// How far along the path each point is; the last is its length.
    private(set) var distances: [Double] = []

    var length: Double { distances.last ?? 0 }

    init(points: [CGPoint], closed: Bool) {
        self.points = points
        self.closed = closed
        if closed, let first = points.first, points.last != first { self.points.append(first) }
        var total = 0.0
        distances = self.points.indices.map { index in
            if index > 0 { total += hypot(self.points[index].x - self.points[index - 1].x, self.points[index].y - self.points[index - 1].y) }
            return total
        }
    }

    /// The first subpath of `path`, its curves cut into `steps` straight
    /// pieces each. Nil when it has no length.
    init?(flattening path: CGPath, steps: Int = 24) {
        var points: [CGPoint] = []
        var closed = false
        var done = false
        path.applyWithBlock { element in
            guard !done else { return }
            let e = element.pointee
            let current = points.last ?? .zero
            switch e.type {
            case .moveToPoint:
                if points.isEmpty { points.append(e.points[0]) } else { done = true }
            case .addLineToPoint:
                points.append(e.points[0])
            case .addQuadCurveToPoint:
                let control = e.points[0], end = e.points[1]
                for step in 1...steps {
                    let t = Double(step) / Double(steps), u = 1 - t
                    points.append(CGPoint(
                        x: u * u * current.x + 2 * u * t * control.x + t * t * end.x,
                        y: u * u * current.y + 2 * u * t * control.y + t * t * end.y
                    ))
                }
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], end = e.points[2]
                for step in 1...steps {
                    let t = Double(step) / Double(steps), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    points.append(CGPoint(
                        x: a * current.x + b * c1.x + c * c2.x + d * end.x,
                        y: a * current.y + b * c1.y + c * c2.y + d * end.y
                    ))
                }
            case .closeSubpath:
                closed = true
                done = true
            @unknown default:
                break
            }
        }
        guard points.count >= 2 else { return nil }
        self.init(points: points, closed: closed)
        guard length > 0 else { return nil }
    }

    /// The point `distance` along the path and the direction it heads
    /// there, in radians (0 to the right, clockwise on screen). A closed
    /// path goes round again; past an open one's ends, along its end's
    /// direction.
    func place(at distance: Double) -> (point: CGPoint, angle: Double) {
        guard points.count >= 2, length > 0 else { return (points.first ?? .zero, 0) }
        var along = distance
        if closed {
            along = along.truncatingRemainder(dividingBy: length)
            if along < 0 { along += length }
        }
        // The piece it falls on: the first whose end is past it.
        let piece: Int
        if along <= 0 {
            piece = 1
        } else if along >= length {
            piece = points.count - 1
        } else {
            var low = 1, high = points.count - 1
            while low < high {
                let middle = (low + high) / 2
                if distances[middle] < along { low = middle + 1 } else { high = middle }
            }
            piece = low
        }
        let start = points[piece - 1], end = points[piece]
        let span = distances[piece] - distances[piece - 1]
        let angle = atan2(end.y - start.y, end.x - start.x)
        let t = span > 0 ? (along - distances[piece - 1]) / span : 0
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        return (point, angle)
    }
}
