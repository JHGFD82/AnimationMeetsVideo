import CoreGraphics
import CoreMedia
import Foundation

/// A Bezier outline drawn with the pen (see docs/pen-tool.md, "A path"):
/// points, each with an in and an out tangent, open or closed. A path
/// control holds one, its vertices' numbers in turn,
/// `[x, y, inX, inY, outX, outY, …]`, so it keyframes as any control's
/// numbers do; whether it is closed is a flag on the control
/// (`EffectControl.closed`), not keyframed.
///
/// A point is in pixels from the middle of the frame, down positive, as a
/// point control is. Tangents are offsets from their point, so a moved
/// point takes them along and two keyframes blend sensibly. A stretch
/// between two points is straight while both tangents that shape it are
/// nothing, and a cubic Bezier otherwise.
struct FreePath: Equatable, Sendable {
    struct Vertex: Equatable, Sendable {
        var point: CGPoint
        /// Toward where the path comes in from, from `point`.
        var inTangent = CGVector.zero
        /// Toward where the path goes on to, from `point`.
        var outTangent = CGVector.zero

        init(_ point: CGPoint, in inTangent: CGVector = .zero, out outTangent: CGVector = .zero) {
            self.point = point
            self.inTangent = inTangent
            self.outTangent = outTangent
        }

        /// Its numbers as a control holds them.
        var values: [Double] {
            [point.x, point.y, inTangent.dx, inTangent.dy, outTangent.dx, outTangent.dy].map { Double($0) }
        }

        var inHandle: CGPoint { point + inTangent }
        var outHandle: CGPoint { point + outTangent }
    }

    /// What a point is, read from its tangents as Illustrator reads it.
    enum VertexKind: String, Sendable {
        /// No tangents: a corner, the path straight into and out of it.
        case linear
        /// Tangents in line with each other: smooth.
        case ease
        /// Tangents not in line: a cusp.
        case broken

        var name: String {
            switch self {
            case .linear: "Linear"
            case .ease: "Ease"
            case .broken: "Broken"
            }
        }
    }

    /// How many numbers each vertex takes in a control.
    static let numbersPerVertex = 6

    var vertices: [Vertex]
    var closed: Bool

    init(vertices: [Vertex] = [], closed: Bool = false) {
        self.vertices = vertices
        self.closed = closed
    }

    /// The path a control's numbers hold, read leniently: six numbers a
    /// vertex, any left over dropped, as are vertices with a number that
    /// isn't finite.
    init(values: [Double], closed: Bool) {
        let n = Self.numbersPerVertex
        vertices = stride(from: 0, to: values.count - n + 1, by: n).compactMap { start in
            let v = values[start..<(start + n)]
            guard v.allSatisfy(\.isFinite) else { return nil }
            let a = Array(v)
            return Vertex(CGPoint(x: a[0], y: a[1]), in: CGVector(dx: a[2], dy: a[3]), out: CGVector(dx: a[4], dy: a[5]))
        }
        self.closed = closed
    }

    /// Its vertices' numbers in turn, as a control holds them.
    var values: [Double] { vertices.flatMap(\.values) }

    var isEmpty: Bool { vertices.isEmpty }

    /// Whether it encloses anything to fill or mask: closed, with at least
    /// two points.
    var encloses: Bool { closed && vertices.count >= 2 }

    // MARK: Stretches

    /// How many stretches it has: one between each two points, and one
    /// back to the first when closed.
    var segmentCount: Int {
        guard vertices.count >= 2 else { return 0 }
        return closed ? vertices.count : vertices.count - 1
    }

    /// The vertex a stretch ends at.
    func segmentEnd(_ index: Int) -> Int { (index + 1) % vertices.count }

    /// Stretch `index`'s four Bezier points: its start, the two handles
    /// that shape it, its end.
    func segment(_ index: Int) -> (p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint) {
        let a = vertices[index], b = vertices[segmentEnd(index)]
        return (a.point, a.outHandle, b.inHandle, b.point)
    }

    /// Whether a stretch is straight: neither tangent that shapes it has
    /// any length.
    func isStraight(_ index: Int) -> Bool {
        vertices[index].outTangent == .zero && vertices[segmentEnd(index)].inTangent == .zero
    }

    /// The point `t` (0...1) of the way along stretch `index`'s curve.
    func point(onSegment index: Int, at t: Double) -> CGPoint {
        let (p0, c1, c2, p3) = segment(index)
        return Self.bezier(p0, c1, c2, p3, t)
    }

    static func bezier(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(
            x: a * p0.x + b * c1.x + c * c2.x + d * p3.x,
            y: a * p0.y + b * c1.y + c * c2.y + d * p3.y
        )
    }

    // MARK: Drawing

    /// The outline, its points offset by `origin` (the middle of the frame
    /// plus a shape's Position), mapped by `transform` if given.
    func cgPath(origin: CGPoint = .zero, transform: CGAffineTransform = .identity) -> CGPath {
        let path = CGMutablePath()
        guard let first = vertices.first else { return path }
        func place(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + origin.x, y: p.y + origin.y).applying(transform) }
        path.move(to: place(first.point))
        for index in 0..<segmentCount {
            let (_, c1, c2, p3) = segment(index)
            if isStraight(index) {
                path.addLine(to: place(p3))
            } else {
                path.addCurve(to: place(p3), control1: place(c1), control2: place(c2))
            }
        }
        if closed, vertices.count >= 2 { path.closeSubpath() }
        return path
    }

    // MARK: Reading points

    /// What vertex `index` is, read from its tangents: none is linear; in
    /// line is ease; otherwise broken. An end of an open path with one
    /// tangent is ease, since it has only the one.
    func kind(of index: Int) -> VertexKind {
        let v = vertices[index]
        let hasIn = v.inTangent != .zero, hasOut = v.outTangent != .zero
        if !hasIn, !hasOut { return .linear }
        let isEnd = !closed && (index == 0 || index == vertices.count - 1)
        guard hasIn, hasOut else { return isEnd ? .ease : .broken }
        return Self.inLine(v.inTangent, v.outTangent) ? .ease : .broken
    }

    /// Whether two tangents point opposite ways along one line, within
    /// half a degree.
    static func inLine(_ a: CGVector, _ b: CGVector) -> Bool {
        let la = a.length, lb = b.length
        guard la > 0, lb > 0 else { return false }
        let cosine = (a.dx * b.dx + a.dy * b.dy) / (la * lb)
        return cosine < -cos(0.5 * .pi / 180)
    }

    // MARK: Editing

    /// Splits stretch `index` at `t` (0...1), keeping the path's shape (de
    /// Casteljau): the new point goes after vertex `index`, and the
    /// tangents either side are shortened to what is left of them. A
    /// straight stretch gets a linear point on it. Returns the new point's
    /// index, or nil for a stretch it doesn't have.
    @discardableResult
    mutating func split(segment index: Int, at t: Double) -> Int? {
        guard (0..<segmentCount).contains(index) else { return nil }
        let t = t.clamped(between: 0, and: 1)
        let next = segmentEnd(index)
        let (p0, c1, c2, p3) = segment(index)
        let at = index + 1
        if isStraight(index) {
            vertices.insert(Vertex(Self.lerp(p0, p3, t)), at: at)
            return at
        }
        let p01 = Self.lerp(p0, c1, t), p12 = Self.lerp(c1, c2, t), p23 = Self.lerp(c2, p3, t)
        let p012 = Self.lerp(p01, p12, t), p123 = Self.lerp(p12, p23, t)
        let middle = Self.lerp(p012, p123, t)
        vertices[index].outTangent = p01 - p0
        vertices[next].inTangent = p23 - p3
        vertices.insert(Vertex(middle, in: p012 - middle, out: p123 - middle), at: at)
        return at
    }

    /// Removes vertex `index`; the points either side keep their tangents.
    mutating func remove(_ index: Int) {
        guard vertices.indices.contains(index) else { return }
        vertices.remove(at: index)
        if vertices.count < 2 { closed = false }
    }

    /// The tangents that make vertex `index` ease when worked out for it
    /// rather than drawn: in line with each other, parallel to the line
    /// between its two neighbours, each a third of the way to its
    /// neighbour. An end of an open path gets one, toward its neighbour.
    /// Nil for a path of one point.
    func easeTangents(for index: Int) -> (in: CGVector, out: CGVector)? {
        let n = vertices.count
        guard n >= 2, vertices.indices.contains(index) else { return nil }
        let p = vertices[index].point
        let hasPrevious = closed || index > 0, hasNext = closed || index < n - 1
        let previous = vertices[(index + n - 1) % n].point, next = vertices[(index + 1) % n].point
        switch (hasPrevious, hasNext) {
        case (true, true):
            let across = next - previous
            guard across.length > 0 else { return nil }
            let direction = across / across.length
            return (direction * -((previous - p).length / 3), direction * ((next - p).length / 3))
        case (false, true):
            return (.zero, (next - p) / 3)
        case (true, false):
            return ((previous - p) / 3, .zero)
        case (false, false):
            return nil
        }
    }

    /// Bends stretch `index` so that its point `t` of the way along passes
    /// through `target`, by moving the two handles that shape it, each in
    /// proportion to how much it pulls there. The tangents either side
    /// change, breaking an ease point's pair.
    mutating func bend(segment index: Int, at t: Double, through target: CGPoint) {
        guard (0..<segmentCount).contains(index) else { return }
        let t = t.clamped(between: 0.05, and: 0.95)
        let next = segmentEnd(index)
        let (p0, c1, c2, p3) = segment(index)
        let now = Self.bezier(p0, c1, c2, p3, t)
        let delta = target - now
        let u = 1 - t
        let k = 1 / (3 * t * u * (u * u + t * t))
        vertices[index].outTangent = (c1 + delta * (k * u)) - p0
        vertices[next].inTangent = (c2 + delta * (k * t)) - p3
    }

    // MARK: Finding

    /// Where on the path is nearest `place`: the stretch, how far along it
    /// (0...1), the point there and how far it is.
    struct Nearest: Equatable, Sendable {
        var segment: Int
        var t: Double
        var point: CGPoint
        var distance: Double
    }

    /// The point on the path nearest `place`; nil with no stretches.
    func nearest(to place: CGPoint) -> Nearest? {
        var best: Nearest?
        for index in 0..<segmentCount {
            let (p0, c1, c2, p3) = segment(index)
            // Sampled, then narrowed around the nearest sample.
            let samples = 48
            var bestT = 0.0, bestD = Double.infinity
            for step in 0...samples {
                let t = Double(step) / Double(samples)
                let d = (Self.bezier(p0, c1, c2, p3, t) - place).length
                if d < bestD { bestD = d; bestT = t }
            }
            var low = max(0, bestT - 1 / Double(samples)), high = min(1, bestT + 1 / Double(samples))
            for _ in 0..<30 {
                let a = low + (high - low) / 3, b = high - (high - low) / 3
                if (Self.bezier(p0, c1, c2, p3, a) - place).length < (Self.bezier(p0, c1, c2, p3, b) - place).length {
                    high = b
                } else {
                    low = a
                }
            }
            let t = (low + high) / 2
            let point = Self.bezier(p0, c1, c2, p3, t)
            let d = (point - place).length
            if d < (best?.distance ?? .infinity) { best = Nearest(segment: index, t: t, point: point, distance: d) }
        }
        return best
    }

    // MARK: Blending

    /// The path between two keyframes' numbers: blended point by point
    /// when they have as many vertices, else the earlier until the later.
    static func blend(_ from: [Double], _ to: [Double], fraction: Double) -> [Double] {
        guard from.count == to.count else { return fraction < 1 ? from : to }
        return zip(from, to).map { Double.interpolate($0, $1, fraction: fraction) }
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

// MARK: - From other outlines

extension FreePath {
    /// The first outline of `path`, as points and tangents: a line is a
    /// stretch between linear points, a curve sets the tangents either
    /// side of it (a quadratic one raised to a cubic), and closing it
    /// joins its last point to its first. Nil when it has fewer than two
    /// points.
    init?(cgPath path: CGPath) {
        var vertices: [Vertex] = []
        var closed = false
        var done = false
        path.applyWithBlock { element in
            guard !done else { return }
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if !vertices.isEmpty {
                    done = true
                    return
                }
                vertices.append(Vertex(e.points[0]))
            case .addLineToPoint:
                vertices.append(Vertex(e.points[0]))
            case .addQuadCurveToPoint:
                guard let last = vertices.last else { return }
                let c = e.points[0], end = e.points[1]
                let c1 = FreePath.lerp(last.point, c, 2.0 / 3), c2 = FreePath.lerp(end, c, 2.0 / 3)
                vertices[vertices.count - 1].outTangent = c1 - last.point
                vertices.append(Vertex(end, in: c2 - end))
            case .addCurveToPoint:
                guard let last = vertices.last else { return }
                vertices[vertices.count - 1].outTangent = e.points[0] - last.point
                vertices.append(Vertex(e.points[2], in: e.points[1] - e.points[2]))
            case .closeSubpath:
                closed = true
                done = true
            @unknown default:
                break
            }
        }
        // A closing stretch drawn out to the first point ends on it: the
        // two are one point.
        if closed, vertices.count > 2, let first = vertices.first, let last = vertices.last,
           hypot(Double(first.point.x - last.point.x), Double(first.point.y - last.point.y)) < 1e-6 {
            vertices[0].inTangent = last.inTangent
            vertices.removeLast()
        }
        guard vertices.count >= 2 else { return nil }
        self.init(vertices: vertices, closed: closed)
    }
}

extension Effect {
    /// The kinds Convert to Path turns into a Path.
    static let convertibleToPath: Set<EffectKind> = [.rectangle, .ellipse, .polygon, .star]

    /// This Rectangle, Ellipse, Polygon or Star as a Path of the same shape
    /// at source time `time`, filled, stroked and placed as it is: its
    /// Position, Fill and Stroke controls come along as they are,
    /// keyframes and all; what made its outline (its size, corners,
    /// points) is the path's points now, and isn't keyframed. Nil for any
    /// other kind, or one with no size.
    func convertedToPath(at time: CMTime) -> Effect? {
        guard Self.convertibleToPath.contains(kind), let step = ShapeStep(self, at: time, center: .zero) else { return nil }
        let offset = control(.shapePosition).flatMap { $0.enabled ? $0.values(at: time) : nil } ?? [0, 0]
        let back = CGAffineTransform(translationX: -(offset.first ?? 0), y: -(offset.count > 1 ? offset[1] : 0))
        guard var outline = FreePath(cgPath: step.path.copy(using: [back]) ?? step.path) else { return nil }
        // Points to a hundredth, tangents to a tenth, so the numbers read
        // as numbers in the file.
        for index in outline.vertices.indices {
            let point = outline.vertices[index].point
            outline.vertices[index].point = CGPoint(x: (point.x * 100).rounded() / 100, y: (point.y * 100).rounded() / 100)
            outline.vertices[index].inTangent = PenTool.tenths(outline.vertices[index].inTangent)
            outline.vertices[index].outTangent = PenTool.tenths(outline.vertices[index].outTangent)
        }
        var path = Effect(kind: .path, name: name)
        path.enabled = enabled
        path.changeControl(.path) { $0.setPath(outline, at: time) }
        for (index, control) in path.controls.enumerated() where control.kind != .path {
            if let own = self.control(control.kind) {
                var kept = own
                kept.id = control.id
                path.controls[index] = kept
            }
        }
        return path
    }
}

private extension CGPath {
    func copy(using transform: [CGAffineTransform]) -> CGPath? {
        var matrix = transform[0]
        return copy(using: &matrix)
    }
}

// MARK: - Vector arithmetic

extension CGVector {
    var length: Double { hypot(Double(dx), Double(dy)) }

    static func * (vector: CGVector, factor: Double) -> CGVector { CGVector(dx: vector.dx * factor, dy: vector.dy * factor) }
    static func / (vector: CGVector, divisor: Double) -> CGVector { CGVector(dx: vector.dx / divisor, dy: vector.dy / divisor) }
    static prefix func - (vector: CGVector) -> CGVector { CGVector(dx: -vector.dx, dy: -vector.dy) }
}

extension CGPoint {
    static func - (a: CGPoint, b: CGPoint) -> CGVector { CGVector(dx: a.x - b.x, dy: a.y - b.y) }
    static func + (point: CGPoint, vector: CGVector) -> CGPoint { CGPoint(x: point.x + vector.dx, y: point.y + vector.dy) }
}

// MARK: - Path controls

extension EffectControl {
    /// The path a path control holds at source time `time`. Between two
    /// keyframes with as many vertices every number blends; with
    /// different numbers the earlier holds until the next.
    func freePath(at time: CMTime) -> FreePath {
        FreePath(values: pathValues(at: time), closed: closed)
    }

    /// A path control's numbers at `time`, by `FreePath.blend`'s rule.
    func pathValues(at time: CMTime) -> [Double] {
        switch number.readings(at: [time])[0] {
        case .blend(let next, let progress):
            let keyframes = number.keyframes
            return FreePath.blend(keyframes[next - 1].value.values, keyframes[next].value.values, fraction: progress)
        case let reading:
            return number.value(of: reading).values
        }
    }

    /// Sets the path at `time` (a keyframe when animated), and whether it
    /// is closed. Adding or removing a point goes through `mapPath`, which
    /// keeps every keyframe's count the same.
    mutating func setPath(_ path: FreePath, at time: CMTime) {
        guard kind.isPath else { return }
        number.set(ComponentValue(values: path.values), at: time)
        closed = path.closed
    }

    /// Changes the path of every keyframe, and the single value, alike:
    /// for adding or removing a point, which acts on every keyframe so
    /// they keep one count and blend everywhere.
    mutating func mapPath(_ change: (inout FreePath) -> Void) {
        guard kind.isPath else { return }
        var closedAfter = closed
        number.mapValues { value in
            var path = FreePath(values: value.values, closed: closed)
            change(&path)
            closedAfter = path.closed
            return ComponentValue(values: path.values)
        }
        closed = closedAfter
    }
}
