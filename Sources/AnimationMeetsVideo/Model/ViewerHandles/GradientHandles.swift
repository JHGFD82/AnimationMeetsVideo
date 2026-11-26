import CoreGraphics
import CoreMedia
import Foundation

/// The gradient of the effect selected in the effects panel, over the
/// picture (see docs/gradients.md, "Where it lies"): its line from start
/// to end (or center to edge), a round handle at each end, a diamond at a
/// radial gradient's focal point, and each stop on the line, to drag as
/// Illustrator's gradient annotator has them. For a shape, text or Stroke
/// effect whose Fill or Stroke holds a gradient: the Fill's when both do.
///
/// The points are shares of the item's bounds or the frame, as the
/// gradient lies, so a drag of a handle by some pixels moves it by that
/// share of them; a stop moves along the line to where the pointer is
/// nearest it.
struct GradientHandles: ViewerHandleSet {
    let effectID: UUID

    /// Whether `effect` paints a gradient whose handles the viewer can show.
    static func applies(to effect: Effect) -> Bool {
        paintedControl(of: effect) != nil
    }

    /// The control whose gradient the handles show: the Fill's, else the
    /// Stroke's, when on and painting one.
    private static func paintedControl(of effect: Effect) -> EffectControl? {
        [ControlKind.fill, .stroke].lazy.compactMap { effect.control($0) }.first { $0.enabled && $0.paint != nil }
    }

    /// What the handles are worked out from: the effect, its gradient now,
    /// how it paints, what its points are shares of, and the matrix from
    /// the effect's coordinates to the frame's after the rest of the stack.
    private struct Placed {
        var effect: Effect
        var control: EffectControl
        var gradient: PaintGradient
        var style: PaintStyle
        var bounds: CGRect
        var matrix: CGAffineTransform

        func point(_ unit: CGPoint) -> CGPoint {
            CGPoint(x: bounds.minX + unit.x * bounds.width, y: bounds.minY + unit.y * bounds.height)
        }

        var start: CGPoint { point(gradient.start) }
        var end: CGPoint { point(gradient.end) }

        /// The radial gradient's own space: its center at the origin, its
        /// edge along x, stretched across by its aspect, as it is drawn.
        var radial: CGAffineTransform {
            let s = start, e = end
            return CGAffineTransform(translationX: s.x, y: s.y)
                .rotated(by: atan2(e.y - s.y, e.x - s.x))
                .scaledBy(x: 1, y: max(gradient.aspect, 0.01))
        }

        var length: Double { hypot(Double(end.x - start.x), Double(end.y - start.y)) }

        var focal: CGPoint {
            CGPoint(x: Double(gradient.focal.x) * length, y: Double(gradient.focal.y) * length).applying(radial)
        }

        /// Where stop `index` is on the line.
        func stop(_ index: Int) -> CGPoint {
            let t = gradient.stops[index].location
            return CGPoint(x: Double(start.x) + Double(end.x - start.x) * t, y: Double(start.y) + Double(end.y - start.y) * t)
        }

        /// A pixel move as a move of a point's shares.
        func unitDelta(_ delta: CGVector) -> CGVector {
            CGVector(dx: bounds.width > 0 ? delta.dx / bounds.width : 0, dy: bounds.height > 0 ? delta.dy / bounds.height : 0)
        }
    }

    private func locate(_ context: HandleContext) -> Placed? {
        guard let found = PointControlHandles.locate(effectID, context),
              let control = Self.paintedControl(of: found.effect), let style = control.paint,
              let gradient = control.gradient(at: context.sourceTime)
        else { return nil }
        let center = CGPoint(x: context.frameSize.width / 2, y: context.frameSize.height / 2)
        let frame = CGRect(origin: .zero, size: context.frameSize)
        // A Stroke effect's gradient lies over what it outlines, as the
        // compositor lays it.
        let outline = found.effect.kind == .stroke
            ? Self.strokedOutline(of: effectID, context)
            : ShapeStep(found.effect, at: context.sourceTime, center: center)?.path
        let item = outline.map(\.boundingBoxOfPath).flatMap { $0.isNull || $0.isEmpty ? nil : $0 } ?? frame
        return Placed(
            effect: found.effect, control: control, gradient: gradient, style: style,
            bounds: style.space == .frame ? frame : item, matrix: found.matrix
        )
    }

    /// What the Stroke effect `effectID` outlines, in its own frame's
    /// pixels: the edges of the shapes above it, strokes and all, where
    /// the moves since have put them (`LayeredCompositor`'s
    /// `.outlineStroke`). A Waveform's marks are left out, since they
    /// need the sound. Nil when nothing above it draws.
    static func strokedOutline(of effectID: UUID, _ context: HandleContext) -> CGPath? {
        let effects = TransformHandles.shownEffects(context.clip, upTo: context.shownUpTo)
        guard let index = effects.index(of: effectID) else { return nil }
        let steps = StackFolding.steps(
            effects: Array(effects.prefix(index)), anchorPoint: context.clip.anchorPoint, at: context.sourceTime, center: context.center
        )
        var edges: [(area: CGPath, transform: CGAffineTransform)] = []
        func union() -> CGPath? {
            edges.reduce(nil as CGPath?) { result, edge in
                var transform = edge.transform
                guard let area = edge.area.copy(using: &transform) else { return result }
                return result.map { $0.union(area) } ?? area
            }
        }
        for step in steps {
            switch step {
            case .place(let matrix, _):
                for e in edges.indices { edges[e].transform = edges[e].transform.concatenating(matrix) }
            case .shape(let shape):
                edges.append((shape.edge, .identity))
            case .outlineStroke(let style):
                if let outline = union() { edges.append((style.area(around: outline), .identity)) }
            default:
                break
            }
        }
        return union()
    }

    // MARK: Handles

    private enum Part: Equatable {
        case start, end, focal
        case stop(Int)

        var id: HandleID {
            switch self {
            case .start: .named("gradient.start")
            case .end: .named("gradient.end")
            case .focal: .named("gradient.focal")
            case .stop(let index): .named("gradient.stop.\(index)")
            }
        }

        init?(_ handle: HandleID) {
            guard case .named(let name) = handle, name.hasPrefix("gradient.") else { return nil }
            switch name {
            case "gradient.start": self = .start
            case "gradient.end": self = .end
            case "gradient.focal": self = .focal
            default:
                guard let index = Int(name.dropFirst("gradient.stop.".count)), name.hasPrefix("gradient.stop.") else { return nil }
                self = .stop(index)
            }
        }
    }

    private func name(of part: Part, _ placed: Placed) -> String {
        let radial = placed.style.kind != .linear
        switch part {
        case .start: return radial ? "Gradient Center" : "Gradient Start"
        case .end: return radial ? "Gradient Edge" : "Gradient End"
        case .focal: return "Gradient Focal Point"
        case .stop(let index): return "Gradient Stop \(index + 1)"
        }
    }

    private func parts(_ placed: Placed) -> [Part] {
        // The stops first, drawn over the ends they may sit on.
        var parts = placed.gradient.stops.indices.map { Part.stop($0) }
        if placed.style.kind == .radial { parts.append(.focal) }
        return parts + [.end, .start]
    }

    private func place(of part: Part, _ placed: Placed) -> CGPoint {
        switch part {
        case .start: placed.start
        case .end: placed.end
        case .focal: placed.focal
        case .stop(let index): placed.stop(index)
        }
    }

    private func value(of part: Part, _ placed: Placed) -> String {
        switch part {
        case .stop(let index): "\(Int((placed.gradient.stops[index].location * 100).rounded()))%"
        case .start, .end, .focal:
            HandleFormat.pair(Double(place(of: part, placed).x), Double(place(of: part, placed).y))
        }
    }

    func handles(_ context: HandleContext) -> [ViewerHandle] {
        guard !context.isLocked, let placed = locate(context) else { return [] }
        return parts(placed).map { part in
            let glyph: HandleGlyph = switch part {
            case .start, .end: .round
            case .focal: .diamond
            case .stop: .vertex
            }
            let name = name(of: part, placed), value = value(of: part, placed)
            return ViewerHandle(
                id: part.id, place: place(of: part, placed).applying(placed.matrix), glyph: glyph, cursor: .move,
                reach: TransformHandles.handleReach, name: name, value: value, hoverText: "\(name) \(value)"
            )
        }
    }

    func outlines(_ context: HandleContext) -> [ViewerOutline] {
        guard !context.isLocked, let placed = locate(context) else { return [] }
        return [ViewerOutline(points: [placed.start, placed.end].map { $0.applying(placed.matrix) }, isClosed: false, style: .guide)]
    }

    func area(at point: CGPoint, _ context: HandleContext) -> HandleID? { nil }

    func pivot(of handle: HandleID, _ context: HandleContext) -> CGPoint? { nil }

    func refusal(for handle: HandleID, _ context: HandleContext) -> HandleRefusal? { nil }

    // MARK: Editing

    func edit(_ drag: HandleDrag, _ context: HandleContext) -> HandleEdit? {
        guard let part = Part(drag.handle), let placed = locate(context) else { return nil }
        var delta = drag.delta
        if drag.shift {
            if abs(delta.dx) >= abs(delta.dy) { delta.dy = 0 } else { delta.dx = 0 }
        }
        if drag.option || drag.fine {
            delta.dx *= 0.1
            delta.dy *= 0.1
        }
        // A move on screen as a move in the effect's coordinates.
        let back = placed.matrix.inverted()
        let moved = CGPoint(x: delta.dx, y: delta.dy).applying(CGAffineTransform(a: back.a, b: back.b, c: back.c, d: back.d, tx: 0, ty: 0))
        return move(part, by: CGVector(dx: moved.x, dy: moved.y), placed, context)
    }

    /// `part` moved `delta` pixels in the effect's coordinates: an end or
    /// the focal point by that much, a stop to where the line is nearest
    /// it now.
    private func move(_ part: Part, by delta: CGVector, _ placed: Placed, _ context: HandleContext) -> HandleEdit? {
        let start = placed.gradient
        var gradient = start
        switch part {
        case .start, .end:
            let unit = placed.unitDelta(delta)
            let from = part == .start ? start.start : start.end
            let to = CGPoint(x: from.x + unit.dx, y: from.y + unit.dy)
            if part == .start { gradient.start = to } else { gradient.end = to }
        case .focal:
            guard placed.length > 0 else { return nil }
            let now = CGPoint(x: placed.focal.x + delta.dx, y: placed.focal.y + delta.dy).applying(placed.radial.inverted())
            // Inside the edge, where a focal point means something.
            var focal = CGPoint(x: Double(now.x) / placed.length, y: Double(now.y) / placed.length)
            let reach = hypot(Double(focal.x), Double(focal.y))
            if reach > 0.99 { focal = CGPoint(x: Double(focal.x) / reach * 0.99, y: Double(focal.y) / reach * 0.99) }
            gradient.focal = focal
        case .stop(let index):
            guard gradient.stops.indices.contains(index) else { return nil }
            let here = placed.stop(index)
            let point = CGPoint(x: here.x + delta.dx, y: here.y + delta.dy)
            let s = placed.start, e = placed.end
            let dx = Double(e.x - s.x), dy = Double(e.y - s.y)
            let squared = dx * dx + dy * dy
            guard squared > 0 else { return nil }
            let t = ((Double(point.x - s.x)) * dx + Double(point.y - s.y) * dy) / squared
            gradient.stops[index].location = t.clamped(between: 0, and: 1)
        }
        guard gradient != start else { return nil }
        return write(gradient, of: part, placed, context)
    }

    func nudge(_ handle: HandleID, _ direction: NudgeDirection, step: NudgeStep, _ context: HandleContext) -> HandleEdit? {
        guard let part = Part(handle), let placed = locate(context) else { return nil }
        let amount = step.multiplier
        if case .stop(let index) = part {
            // A percent along the line, ten with Shift.
            guard placed.gradient.stops.indices.contains(index) else { return nil }
            var gradient = placed.gradient
            let sign: Double = direction == .right || direction == .up ? 1 : -1
            gradient.stops[index].location = (gradient.stops[index].location + sign * amount / 100).clamped(between: 0, and: 1)
            return write(gradient, of: part, placed, context)
        }
        let (dx, dy): (Double, Double) = switch direction {
        case .left: (-amount, 0)
        case .right: (amount, 0)
        case .up: (0, -amount)
        case .down: (0, amount)
        }
        return move(part, by: CGVector(dx: dx, dy: dy), placed, context)
    }

    func reset(_ handle: HandleID, _ context: HandleContext) -> HandleEdit? {
        guard let part = Part(handle), let placed = locate(context) else { return nil }
        let fresh = PaintGradient.made(placed.style.kind, from: [0, 0, 0, 1], to: [1, 1, 1, 1])
        var gradient = placed.gradient
        switch part {
        case .start: gradient.start = fresh.start
        case .end: gradient.end = fresh.end
        case .focal: gradient.focal = .zero
        case .stop: return nil
        }
        guard gradient != placed.gradient else { return nil }
        return write(gradient, of: part, placed, context, actionName: "Reset \(name(of: part, placed))")
    }

    func keyTargets(_ context: HandleContext) -> [HandleKeyTarget] {
        guard let placed = locate(context) else { return [] }
        return parts(placed).reversed().map { part in
            let name = name(of: part, placed), value = value(of: part, placed)
            if case .stop = part {
                return HandleKeyTarget(handle: part.id, name: name, value: value, axes: [
                    HandleAxis(name: "\(name) Location", value: value, increment: .right, decrement: .left,
                               larger: ("Move 10 percent along", "Move 10 percent back")),
                ])
            }
            let at = place(of: part, placed)
            return HandleKeyTarget(handle: part.id, name: name, value: value, axes: [
                HandleAxis(name: "\(name) X", value: "\(HandleFormat.number(Double(at.x))) pixels", increment: .right, decrement: .left,
                           larger: ("Move 10 pixels right", "Move 10 pixels left")),
                HandleAxis(name: "\(name) Y", value: "\(HandleFormat.number(Double(at.y))) pixels", increment: .down, decrement: .up,
                           larger: ("Move 10 pixels down", "Move 10 pixels up")),
            ])
        }
    }

    /// The gradient as `gradient`, written as the inspector writes it: at
    /// a keyframe at the playhead when it is keyframed.
    private func write(_ gradient: PaintGradient, of part: Part, _ placed: Placed, _ context: HandleContext, actionName: String? = nil) -> HandleEdit? {
        var result = context.clip
        guard let index = result.effects.index(of: placed.effect.id) else { return nil }
        let at = context.sourceTime
        result.effects[index].changeControl(placed.control.kind) { control in
            control.editGradient(at: at) { $0 = gradient }
        }
        let name = name(of: part, placed)
        var shown = placed
        shown.gradient = gradient
        return HandleEdit(change: { $0 = result }, readout: "\(name) \(value(of: part, shown))", actionName: actionName ?? "Move \(name)")
    }
}
