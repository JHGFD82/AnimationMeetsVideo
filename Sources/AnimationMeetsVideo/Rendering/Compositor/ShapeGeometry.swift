import CoreGraphics
import CoreMedia
import Foundation

/// A shape as drawn at one moment: its outline in the frame's pixels
/// (origin top left, y down), and how it is filled and stroked.
struct ShapeStep: Equatable, Sendable {
    enum Outline: Equatable, Sendable {
        /// With `squircle`, corners of continuous curvature.
        case rectangle(CGRect, cornerRadius: Double, squircle: Bool)
        case ellipse(CGRect)
        /// A regular polygon, or with an inner radius a star, with its
        /// first point straight up from the center before `rotation`
        /// (degrees, clockwise).
        case polygon(center: CGPoint, points: Int, radius: Double, innerRadius: Double?, cornerRadius: Double, rotation: Double)
        /// A block of text, whose outline is its glyphs.
        case text(TextOutline)
    }

    var outline: Outline
    /// Red, green, blue and alpha (0...1, not premultiplied); nil when it
    /// isn't filled.
    var fill: [Double]?
    /// Nil when it isn't stroked.
    var stroke: ShapeStroke?

    /// The shape of a Rectangle, Ellipse, Polygon, Star or Text effect at
    /// source time `time`, centered on `center` plus its Position. Nil when
    /// it has no size, or is text with no words. A shape with neither a fill nor a stroke draws nothing
    /// but still has an outline for a Stroke below it to follow.
    /// A Text effect's `animators` are the Text Animator effects below it,
    /// and `followed` the outline of the shape above it, which it follows
    /// while it is On Path.
    init?(_ effect: Effect, at time: CMTime, center: CGPoint, animators: [Effect] = [], followed: TextPath? = nil) {
        func values(_ kind: ControlKind) -> [Double] {
            guard let control = effect.control(kind), control.enabled else { return kind.defaultValues }
            return control.values(at: time)
        }
        func single(_ kind: ControlKind) -> Double { values(kind).first ?? 0 }
        let offset = values(.shapePosition)
        guard offset.count == 2 else { return nil }
        let middle = CGPoint(x: center.x + offset[0], y: center.y + offset[1])
        switch effect.kind {
        case .rectangle, .ellipse:
            let size = values(.shapeSize)
            guard size.count == 2, size[0] > 0, size[1] > 0 else { return nil }
            let rect = CGRect(x: middle.x - size[0] / 2, y: middle.y - size[1] / 2, width: size[0], height: size[1])
            let squircle = effect.control(.cornerRadius).map { $0.enabled && $0.squircle } ?? false
            outline = effect.kind == .ellipse
                ? .ellipse(rect)
                : .rectangle(rect, cornerRadius: max(0, single(.cornerRadius)), squircle: squircle)
        case .polygon, .star:
            let radius = single(.radius)
            guard radius > 0 else { return nil }
            outline = .polygon(
                center: middle, points: Int(ControlKind.points.clamped(single(.points))), radius: radius,
                innerRadius: effect.kind == .star ? max(0, single(.innerRadius)) : nil,
                cornerRadius: max(0, single(.cornerRadius)), rotation: single(.shapeRotation)
            )
        case .text:
            guard let setting = TextOutline.Setting(effect, at: time) else { return nil }
            var text = TextOutline(setting: setting, center: middle, animators: animators.compactMap { TextOutline.Animator($0, at: time) })
            if let followed, effect.control(.textOnPath).map({ $0.enabled && $0.choice == OnOff.on.rawValue }) ?? false {
                text.followed = followed
                text.pathOffset = single(.pathOffset)
            }
            outline = .text(text)
        default:
            return nil
        }
        if let control = effect.control(.fill), control.enabled {
            let rgba = control.values(at: time).map { $0.clamped(between: 0, and: 1) }
            fill = rgba.count == 4 && rgba[3] > 0 ? rgba : nil
        }
        stroke = ShapeStroke(effect, at: time)
    }

    /// The outline as a path in the frame's pixels.
    var path: CGPath {
        switch outline {
        case .rectangle(let rect, let radius, let squircle):
            if squircle, radius > 0 { return Self.squirclePath(in: rect, cornerRadius: radius) }
            // Corners can be no rounder than half the shorter side.
            let corner = min(radius, rect.width / 2, rect.height / 2)
            return corner > 0
                ? CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
                : CGPath(rect: rect, transform: nil)
        case .ellipse(let rect):
            return CGPath(ellipseIn: rect, transform: nil)
        case .polygon(let center, let points, let radius, let inner, let corner, let rotation):
            let count = inner == nil ? points : points * 2
            let first = rotation * .pi / 180 - .pi / 2
            let vertices = (0..<count).map { k in
                let reach = inner != nil && k % 2 == 1 ? inner! : radius
                let angle = first + 2 * .pi * Double(k) / Double(count)
                return CGPoint(x: center.x + reach * cos(angle), y: center.y + reach * sin(angle))
            }
            return Self.closedPath(through: vertices, cornerRadius: corner)
        case .text(let text):
            return text.path
        }
    }

    /// What it paints, bottom first: its fill, then its stroke, each an
    /// area filled with a color.
    /// Text paints each group of letters drawn alike in its own colors and
    /// opacity, all the fills first, then the strokes.
    var paints: [(area: CGPath, color: [Double])] {
        if case .text(let text) = outline {
            let pieces = text.pieces(fill: fill, stroke: stroke?.color)
            func faded(_ color: [Double], _ opacity: Double) -> [Double] {
                color.count == 4 ? [color[0], color[1], color[2], color[3] * opacity] : color
            }
            var result = pieces.compactMap { piece in piece.fill.map { (piece.path as CGPath, faded($0, piece.opacity)) } }
            if let stroke {
                result += pieces.compactMap { piece in
                    piece.stroke.map { (stroke.area(around: piece.path), faded($0, piece.opacity)) }
                }
            }
            return result
        }
        let outline = path
        var result: [(area: CGPath, color: [Double])] = []
        if let fill { result.append((outline, fill)) }
        if let stroke { result.append((stroke.area(around: outline), stroke.color)) }
        return result
    }

    /// Its edge, which a Stroke below it follows: the outline, with its
    /// stroke's area when it has one.
    var edge: CGPath {
        let outline = path
        guard let stroke else { return outline }
        return outline.union(stroke.area(around: outline))
    }

    /// What it draws, in words, for a render's key.
    var keyText: String {
        func n(_ value: Double) -> String { String(format: "%.5f", value) }
        func rect(_ r: CGRect) -> String { [r.minX, r.minY, r.width, r.height].map { n(Double($0)) }.joined(separator: ",") }
        var text: String
        switch outline {
        case .rectangle(let r, let radius, let squircle): text = "h r\(n(radius))\(squircle ? "q" : "") \(rect(r))"
        case .ellipse(let r): text = "h e \(rect(r))"
        case .polygon(let c, let points, let radius, let inner, let corner, let rotation):
            text = "h p\(points) \(n(c.x)),\(n(c.y)) \(n(radius)) \(inner.map(n) ?? "-") \(n(corner)) \(n(rotation))"
        case .text(let outline):
            text = outline.keyText
        }
        text += " f" + (fill ?? []).map(n).joined(separator: ",")
        text += " s" + (stroke?.keyText ?? "-")
        return text
    }

    /// How much further along each edge a squircle's corner reaches than a
    /// circular corner of the same radius, close to Apple's app icons.
    static let squircleReach = 1.6
    /// The exponent of a squircle's corners: 2 would be a circle; higher
    /// is squarer, with the corner flat where it meets the edge.
    static let squircleExponent = 5.0

    /// `rect` with squircle corners: each a quarter of a superellipse
    /// (|x|ⁿ + |y|ⁿ = 1), whose curvature falls to nothing where it meets
    /// the edge, so the corner eases into it instead of a circular arc
    /// meeting it abruptly. A corner reaches `squircleReach * radius` along
    /// each edge, at most half the shorter side, where the rectangle's sides
    /// are all corner and it is a squircle through and through.
    static func squirclePath(in rect: CGRect, cornerRadius: Double) -> CGPath {
        let reach = min(cornerRadius * squircleReach, Double(min(rect.width, rect.height)) / 2)
        guard reach > 0 else { return CGPath(rect: rect, transform: nil) }
        let path = CGMutablePath()
        // Clockwise on screen from the top left (y down): each corner with
        // the direction along the edge into it and out of it.
        let corners: [(corner: CGPoint, into: CGVector, out: CGVector)] = [
            (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
            (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
        ]
        // Enough steps that no chord strays a visible fraction of a pixel
        // from the curve at the sizes a frame holds.
        let steps = 48
        let power = 2 / squircleExponent
        for (index, (corner, u, v)) in corners.enumerated() {
            for step in 0...steps {
                // From the edge coming in (θ = π/2) round to the edge going out.
                let theta = Double.pi / 2 * (1 - Double(step) / Double(steps))
                let along = reach * pow(cos(theta), power)
                let back = reach * pow(sin(theta), power)
                // Measured from the corner region's inner point, `reach` back
                // along the edge in and `reach` along the edge out.
                let x = -reach + along, y = reach - back
                let point = CGPoint(x: corner.x + u.dx * x + v.dx * y, y: corner.y + u.dy * x + v.dy * y)
                if index == 0, step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        path.closeSubpath()
        return path
    }

    /// A closed path through `vertices`, each corner rounded to at most
    /// `cornerRadius`: as round as fits within half of each edge beside it.
    static func closedPath(through vertices: [CGPoint], cornerRadius: Double) -> CGPath {
        let path = CGMutablePath()
        let n = vertices.count
        guard n >= 3 else { return path }
        guard cornerRadius > 0 else {
            path.addLines(between: vertices)
            path.closeSubpath()
            return path
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(b.x - a.x), Double(b.y - a.y)) }
        // Halfway along the last edge, so every corner is rounded the same way.
        path.move(to: CGPoint(x: (vertices[n - 1].x + vertices[0].x) / 2, y: (vertices[n - 1].y + vertices[0].y) / 2))
        for k in 0..<n {
            let previous = vertices[(k + n - 1) % n], corner = vertices[k], next = vertices[(k + 1) % n]
            let a = distance(corner, previous), b = distance(corner, next)
            guard a > 0, b > 0 else { continue }
            let cosine = (Double(previous.x - corner.x) * Double(next.x - corner.x) + Double(previous.y - corner.y) * Double(next.y - corner.y)) / (a * b)
            let angle = acos(cosine.clamped(between: -1, and: 1))
            // The arc meets each edge radius / tan(angle / 2) from the corner.
            let radius = min(cornerRadius, min(a, b) / 2 * tan(angle / 2))
            path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
        }
        path.closeSubpath()
        return path
    }
}

/// How a stroke is drawn: its color and width, which side of the outline
/// it goes, how it turns corners and ends dashes, and its dashes.
struct ShapeStroke: Equatable, Sendable {
    /// Red, green, blue and alpha, 0...1.
    var color: [Double]
    var width: Double
    var edge: StrokeEdge
    var join: StrokeJoin
    var cap: StrokeCap
    /// The length of each dash and of the gap after it; solid while the
    /// dash is 0. A gap of 0 is as long as the dash.
    var dash: Double
    var gap: Double

    /// The stroke an effect's controls give at source time `time`: its
    /// Stroke color, Stroke Width, Edge, Join, Cap and Dash. Nil when the
    /// color is off or clear, or there is no width.
    init?(_ effect: Effect, at time: CMTime) {
        guard let colorControl = effect.control(.stroke), colorControl.enabled else { return nil }
        let rgba = colorControl.values(at: time).map { $0.clamped(between: 0, and: 1) }
        guard rgba.count == 4, rgba[3] > 0 else { return nil }
        let widthControl = effect.control(.strokeWidth).flatMap { $0.enabled ? $0 : nil }
        let width = widthControl?.values(at: time).first ?? 0
        guard width > 0 else { return nil }
        func choice(_ kind: ControlKind) -> String {
            effect.control(kind).flatMap { $0.enabled ? $0.choice : nil } ?? kind.defaultChoice ?? ""
        }
        let dashes = effect.control(.dash).flatMap { $0.enabled ? $0.values(at: time) : nil } ?? [0, 0]
        color = rgba
        self.width = width
        edge = StrokeEdge(rawValue: choice(.strokeEdge)) ?? .center
        join = StrokeJoin(rawValue: choice(.strokeJoin)) ?? .miter
        cap = StrokeCap(rawValue: choice(.strokeCap)) ?? .butt
        dash = max(0, dashes.first ?? 0)
        gap = max(0, dashes.count > 1 ? dashes[1] : 0)
    }

    /// The area the stroke covers along `outline`, to be filled. Inside and
    /// outside strokes are a centered stroke twice as wide, cut to that side
    /// of the outline, so their corners are the outline's own.
    func area(around outline: CGPath) -> CGPath {
        var line = outline
        if dash > 0 {
            line = outline.copy(dashingWithPhase: 0, lengths: [dash, gap > 0 ? gap : dash])
        }
        switch edge {
        case .center:
            return line.copy(strokingWithWidth: width, lineCap: cap.cgCap, lineJoin: join.cgJoin, miterLimit: 10)
        case .inside:
            return line.copy(strokingWithWidth: width * 2, lineCap: cap.cgCap, lineJoin: join.cgJoin, miterLimit: 10)
                .intersection(outline)
        case .outside:
            return line.copy(strokingWithWidth: width * 2, lineCap: cap.cgCap, lineJoin: join.cgJoin, miterLimit: 10)
                .subtracting(outline)
        }
    }

    /// What it draws, in words, for a render's key.
    var keyText: String {
        func n(_ value: Double) -> String { String(format: "%.5f", value) }
        return color.map(n).joined(separator: ",") + "@\(n(width)) \(edge.rawValue) \(join.rawValue) \(cap.rawValue) \(n(dash))/\(n(gap))"
    }
}
