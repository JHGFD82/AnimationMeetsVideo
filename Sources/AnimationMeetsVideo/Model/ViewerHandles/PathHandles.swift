import CoreGraphics
import CoreMedia
import Foundation

/// The handles of a Path or Path Mask selected in the effects panel (see
/// docs/pen-tool.md, "Editing a path"): every point of its path, and the
/// tangents of the picked point and the points either side of it, the
/// ones that shape the stretches it touches. They work in the effect's
/// coordinates at its place in the stack, mapped through the Transform
/// effects below it as an effect's points are
/// (`PointControlHandles.locate`). A Path's points are measured from the
/// middle of the frame plus its Position; a mask's from the middle.
///
/// The arrow moves points and tangents; the pen adds, removes and converts
/// them (`PenTool`), with the edits here.
struct PathHandles: ViewerHandleSet {
    let effectID: UUID

    static func applies(to effect: Effect) -> Bool {
        effect.kind == .path || effect.kind == .pathMask
    }

    /// One of the handles: a point, or one of its tangents.
    enum Part: Equatable, Hashable, Sendable {
        case vertex(Int)
        case tangent(Int, TangentSide)

        var handle: HandleID {
            switch self {
            case .vertex(let index): .named("vertex:\(index)")
            case .tangent(let index, .in): .named("in:\(index)")
            case .tangent(let index, .out): .named("out:\(index)")
            }
        }

        init?(_ handle: HandleID?) {
            guard case .named(let name)? = handle else { return nil }
            let parts = name.split(separator: ":")
            guard parts.count == 2, let index = Int(parts[1]) else { return nil }
            switch parts[0] {
            case "vertex": self = .vertex(index)
            case "in": self = .tangent(index, .in)
            case "out": self = .tangent(index, .out)
            default: return nil
            }
        }

        /// The point it is, or belongs to.
        var vertex: Int {
            switch self {
            case .vertex(let index), .tangent(let index, _): index
            }
        }
    }

    /// The path where the viewer shows it.
    struct Located {
        var effect: Effect
        var control: EffectControl
        /// The path at the playhead.
        var path: FreePath
        /// From the path's own coordinates to the frame's pixels after the
        /// rest of the stack.
        var toFrame: CGAffineTransform
        var sourceTime: CMTime

        /// A place in the frame as a place in the path's coordinates; nil
        /// when the stack scales it to nothing.
        func toPath(_ point: CGPoint) -> CGPoint? {
            guard abs(toFrame.a * toFrame.d - toFrame.b * toFrame.c) > 1e-12 else { return nil }
            return point.applying(toFrame.inverted())
        }

        /// A movement in the frame as one in the path's coordinates.
        func toPath(_ vector: CGVector) -> CGVector {
            let back = toFrame.inverted()
            let moved = CGPoint(x: vector.dx, y: vector.dy).applying(CGAffineTransform(a: back.a, b: back.b, c: back.c, d: back.d, tx: 0, ty: 0))
            return CGVector(dx: moved.x, dy: moved.y)
        }

        func frame(_ point: CGPoint) -> CGPoint { point.applying(toFrame) }
    }

    /// The path of the effect with ID `effectID` where the viewer shows
    /// it, at the playhead; nil when the effect is off, cut off by Show Up
    /// to Here, under a Transform that scales it to nothing, or not a path.
    static func locate(_ effectID: UUID, _ context: HandleContext) -> Located? {
        guard let found = PointControlHandles.locate(effectID, context), applies(to: found.effect),
              let control = found.effect.control(.path)
        else { return nil }
        var origin = context.center
        if found.effect.kind == .path, let position = found.effect.control(.shapePosition), position.enabled {
            let values = position.values(at: context.sourceTime)
            if values.count == 2 { origin = CGPoint(x: origin.x + values[0], y: origin.y + values[1]) }
        }
        return Located(
            effect: found.effect, control: control, path: control.freePath(at: context.sourceTime),
            toFrame: CGAffineTransform(translationX: origin.x, y: origin.y).concatenating(found.matrix),
            sourceTime: context.sourceTime
        )
    }

    /// The points whose tangents show: the picked one and those either
    /// side of it.
    static func pointsShowingTangents(of path: FreePath, picked: Int?) -> [Int] {
        guard let picked, path.vertices.indices.contains(picked) else { return [] }
        let n = path.vertices.count
        var shown = [picked]
        if path.closed || picked > 0 { shown.append((picked + n - 1) % n) }
        if path.closed || picked < n - 1 { shown.append((picked + 1) % n) }
        return Array(Set(shown)).sorted()
    }

    /// The points picked: those picked together, with the picked one, all
    /// on the path.
    static func selected(_ context: HandleContext, in path: FreePath) -> Set<Int> {
        var points = context.pickedPoints
        if let picked = Part(context.picked)?.vertex { points.insert(picked) }
        return points.filter { path.vertices.indices.contains($0) }
    }

    // MARK: The set

    func handles(_ context: HandleContext) -> [ViewerHandle] {
        guard !context.isLocked, let located = Self.locate(effectID, context) else { return [] }
        let refusal = Self.driver(of: located, in: context.clip)
        let path = located.path
        let picked = Part(context.picked)?.vertex
        let selected = Self.selected(context, in: path)
        var list: [ViewerHandle] = []
        // Tangents first: drawn over the points, so asked first.
        for index in Self.pointsShowingTangents(of: path, picked: picked) {
            let vertex = path.vertices[index]
            for (side, tangent) in [(TangentSide.in, vertex.inTangent), (.out, vertex.outTangent)] where tangent != .zero {
                list.append(ViewerHandle(
                    id: Part.tangent(index, side).handle, place: located.frame(vertex.point + tangent), glyph: .tangent,
                    cursor: refusal == nil ? .move : .notAllowed, reach: 5, isEnabled: refusal == nil, refusal: refusal,
                    name: "\(side == .in ? "In" : "Out") Tangent of Point \(index + 1)",
                    value: HandleFormat.pair(Double(tangent.dx), Double(tangent.dy))
                ))
            }
        }
        for index in path.vertices.indices {
            let vertex = path.vertices[index]
            list.append(ViewerHandle(
                id: Part.vertex(index).handle, place: located.frame(vertex.point), glyph: selected.contains(index) ? .pickedVertex : .vertex,
                cursor: refusal == nil ? .move : .notAllowed, reach: TransformHandles.handleReach,
                isEnabled: refusal == nil, refusal: refusal, name: Self.name(of: index, in: path),
                value: Self.text(of: index, in: path)
            ))
        }
        return list
    }

    func outlines(_ context: HandleContext) -> [ViewerOutline] {
        guard let located = Self.locate(effectID, context) else { return [] }
        return Self.outlines(of: located, picked: Part(context.picked)?.vertex)
    }

    /// The path, its curves cut into short lines, and the lines out to the
    /// tangents that show, in the frame's pixels.
    static func outlines(of located: Located, picked: Int?) -> [ViewerOutline] {
        let path = located.path
        guard !path.isEmpty else { return [] }
        var result = [ViewerOutline(points: flattened(path).map(located.frame), isClosed: path.closed, style: .path)]
        for index in pointsShowingTangents(of: path, picked: picked) {
            let vertex = path.vertices[index]
            for tangent in [vertex.inTangent, vertex.outTangent] where tangent != .zero {
                result.append(ViewerOutline(
                    points: [located.frame(vertex.point), located.frame(vertex.point + tangent)], isClosed: false, style: .tangent
                ))
            }
        }
        return result
    }

    /// The path's points in order, each curved stretch cut into 24 lines.
    static func flattened(_ path: FreePath) -> [CGPoint] {
        guard let first = path.vertices.first else { return [] }
        var points = [first.point]
        for index in 0..<path.segmentCount {
            if path.isStraight(index) {
                points.append(path.segment(index).p3)
            } else {
                for step in 1...24 { points.append(path.point(onSegment: index, at: Double(step) / 24)) }
            }
        }
        // A closed path's last stretch ends at its first point, which
        // closing the outline joins up again.
        if path.closed, points.count > 1 { points.removeLast() }
        return points
    }

    func area(at point: CGPoint, _ context: HandleContext) -> HandleID? { nil }

    func pivot(of handle: HandleID, _ context: HandleContext) -> CGPoint? { nil }

    /// "Point 3 of 12".
    static func name(of index: Int, in path: FreePath) -> String {
        "Point \(index + 1) of \(path.vertices.count)"
    }

    /// "ease, 120, −40".
    static func text(of index: Int, in path: FreePath) -> String {
        let point = path.vertices[index].point
        return "\(path.kind(of: index).name.lowercased()), \(HandleFormat.pair(Double(point.x), Double(point.y)))"
    }

    // MARK: Refusals

    /// The refusal a path the Keyframing effect drives gives.
    static func driver(of located: Located, in clip: TimelineClip) -> HandleRefusal? {
        let target = KeyframingTarget.control(effectID: located.effect.id, controlID: located.control.id)
        guard let driver = clip.effects.first(where: { $0.keyframing?.target == target }) else { return nil }
        return .driven(keyframingEffectID: driver.id, effectID: located.effect.id, controlID: located.control.id)
    }

    func refusal(for handle: HandleID, _ context: HandleContext) -> HandleRefusal? {
        guard Part(handle) != nil, let located = Self.locate(effectID, context) else { return nil }
        return Self.driver(of: located, in: context.clip)
    }

    // MARK: Dragging

    /// A point follows the pointer in whole pixels of the path's
    /// coordinates, its tangents with it, and the other points picked with
    /// it by as much; with Shift kept to the axis the drag is nearer on
    /// screen, with Option a tenth of the pointer's movement, in tenths. A tangent's end follows the pointer, in
    /// tenths; on an ease point the opposite tangent stays in line with it
    /// at its own length, and on a broken one it moves alone.
    func edit(_ drag: HandleDrag, _ context: HandleContext) -> HandleEdit? {
        guard let part = Part(drag.handle), let located = Self.locate(effectID, context),
              located.path.vertices.indices.contains(part.vertex)
        else { return nil }
        var path = located.path
        switch part {
        case .vertex(let index):
            var delta = drag.delta
            if drag.shift {
                if abs(delta.dx) >= abs(delta.dy) { delta.dy = 0 } else { delta.dx = 0 }
            }
            if drag.option {
                delta.dx *= 0.1
                delta.dy *= 0.1
            }
            let change = located.toPath(delta)
            let step = drag.option || drag.fine ? 0.1 : 1
            let start = path.vertices[index].point
            let moved = CGPoint(
                x: ((Double(start.x) + Double(change.dx)) / step).rounded() * step,
                y: ((Double(start.y) + Double(change.dy)) / step).rounded() * step
            )
            guard moved != start else { return nil }
            let selected = Self.selected(context, in: path)
            guard selected.count > 1, selected.contains(index) else {
                path.vertices[index].point = moved
                return write(path, located, context, readout: "Point \(index + 1) \(HandleFormat.pair(Double(moved.x), Double(moved.y)))", actionName: "Move Point")
            }
            // The others picked move as far as this one did.
            let dx = moved.x - start.x, dy = moved.y - start.y
            for other in selected { path.vertices[other].point = CGPoint(x: path.vertices[other].point.x + dx, y: path.vertices[other].point.y + dy) }
            return write(path, located, context, readout: "\(selected.count) Points \(HandleFormat.pair(Double(dx), Double(dy)))", actionName: "Move Points")
        case .tangent(let index, let side):
            let vertex = path.vertices[index]
            let start = side == .in ? vertex.inTangent : vertex.outTangent
            var tangent: CGVector
            if drag.option || drag.fine {
                let change = located.toPath(drag.delta) * 0.1
                tangent = CGVector(dx: start.dx + change.dx, dy: start.dy + change.dy)
            } else {
                guard let pointer = located.toPath(drag.now) else { return nil }
                tangent = pointer - vertex.point
            }
            if drag.shift { tangent = PenTool.snapped45(tangent) }
            tangent = PenTool.tenths(tangent)
            let keepsPair = path.kind(of: index) == .ease
            path = Self.moving(tangent: side, of: index, in: path, to: tangent, keepsPair: keepsPair)
            guard path != located.path else { return nil }
            return write(path, located, context, readout: "Tangent \(HandleFormat.pair(Double(tangent.dx), Double(tangent.dy)))", actionName: "Move Tangent")
        }
    }

    /// `path` with point `index`'s tangent on `side` at `tangent`; with
    /// `keepsPair`, the opposite one turned to stay in line with it, at its
    /// own length.
    static func moving(tangent side: TangentSide, of index: Int, in path: FreePath, to tangent: CGVector, keepsPair: Bool) -> FreePath {
        var path = path
        let other = side == .in ? path.vertices[index].outTangent : path.vertices[index].inTangent
        if side == .in { path.vertices[index].inTangent = tangent } else { path.vertices[index].outTangent = tangent }
        if keepsPair, other != .zero, tangent.length > 0 {
            let opposite = PenTool.tenths(-tangent * (other.length / tangent.length))
            if side == .in { path.vertices[index].outTangent = opposite } else { path.vertices[index].inTangent = opposite }
        }
        return path
    }

    func nudge(_ handle: HandleID, _ direction: NudgeDirection, step: NudgeStep, _ context: HandleContext) -> HandleEdit? {
        guard case .vertex(let index)? = Part(handle), let located = Self.locate(effectID, context),
              located.path.vertices.indices.contains(index)
        else { return nil }
        let (dx, dy): (Double, Double) = switch direction {
        case .left: (-1, 0)
        case .right: (1, 0)
        case .up: (0, -1)
        case .down: (0, 1)
        }
        var path = located.path
        // The points picked with it go too.
        let selected = Self.selected(context, in: path)
        let moving = selected.contains(index) ? selected : [index]
        for point in moving {
            let place = path.vertices[point].point
            path.vertices[point].point = CGPoint(
                x: ((Double(place.x) + dx * step.multiplier) * 10).rounded() / 10,
                y: ((Double(place.y) + dy * step.multiplier) * 10).rounded() / 10
            )
        }
        let moved = path.vertices[index].point
        let readout = moving.count > 1
            ? "\(moving.count) Points" : "Point \(index + 1) \(HandleFormat.pair(Double(moved.x), Double(moved.y)))"
        return write(path, located, context, readout: readout, actionName: moving.count > 1 ? "Move Points" : "Move Point")
    }

    func reset(_ handle: HandleID, _ context: HandleContext) -> HandleEdit? { nil }

    func keyTargets(_ context: HandleContext) -> [HandleKeyTarget] {
        guard let located = Self.locate(effectID, context) else { return [] }
        let path = located.path
        return path.vertices.indices.map { index in
            let point = path.vertices[index].point
            let name = "Point \(index + 1)"
            let kind = path.kind(of: index)
            var actions = [
                HandleAction(name: "Add Point After") { context in edit(context, name: "Add Point") { Self.addingPoint(after: index, to: &$0) } },
                HandleAction(name: "Remove Point") { context in edit(context, name: "Remove Point") { $0.mapPath { $0.remove(index) } } },
                HandleAction(name: kind == .linear ? "Make Ease" : "Make Linear") { context in
                    edit(context, name: "Convert Point") { control in Self.converting(index, of: &control, at: context.sourceTime) }
                },
            ]
            if path.vertices.count >= 2 {
                actions.append(HandleAction(name: path.closed ? "Open Path" : "Close Path") { context in
                    edit(context, name: path.closed ? "Open Path" : "Close Path") { $0.closed.toggle() }
                })
            }
            return HandleKeyTarget(
                handle: Part.vertex(index).handle, name: Self.name(of: index, in: path), value: Self.text(of: index, in: path),
                axes: [
                    HandleAxis(name: "\(name) X, \(kind.name.lowercased())", value: "\(HandleFormat.number(Double(point.x))) pixels",
                               increment: .right, decrement: .left, larger: ("Move 10 pixels right", "Move 10 pixels left")),
                    HandleAxis(name: "\(name) Y, \(kind.name.lowercased())", value: "\(HandleFormat.number(Double(point.y))) pixels",
                               increment: .down, decrement: .up, larger: ("Move 10 pixels down", "Move 10 pixels up")),
                ],
                actions: actions
            )
        }
    }

    // MARK: Edits

    /// A point added after `index`: halfway along the stretch after it, or
    /// past the end of an open path, as far again as the last stretch
    /// went; on every keyframe, so they keep one count.
    static func addingPoint(after index: Int, to control: inout EffectControl) {
        control.mapPath { path in
            guard path.vertices.indices.contains(index) else { return }
            if index < path.segmentCount {
                path.split(segment: index, at: 0.5)
            } else {
                let last = path.vertices[index].point
                let before = index > 0 ? path.vertices[index - 1].point : CGPoint(x: last.x - 40, y: last.y)
                path.vertices.insert(FreePath.Vertex(CGPoint(x: (2 * last.x - before.x).rounded(), y: (2 * last.y - before.y).rounded())), at: index + 1)
            }
        }
    }

    /// Point `index` switched at `time` between linear and ease: an ease
    /// or broken point loses its tangents; a linear one gets them worked
    /// out (`FreePath.easeTangents`).
    static func converting(_ index: Int, of control: inout EffectControl, at time: CMTime) {
        var path = control.freePath(at: time)
        guard path.vertices.indices.contains(index) else { return }
        if path.kind(of: index) == .linear {
            guard let tangents = path.easeTangents(for: index) else { return }
            path.vertices[index].inTangent = PenTool.tenths(tangents.in)
            path.vertices[index].outTangent = PenTool.tenths(tangents.out)
        } else {
            path.vertices[index].inTangent = .zero
            path.vertices[index].outTangent = .zero
        }
        control.setPath(path, at: time)
    }

    /// An edit of the path control, from the clip in `context`.
    private func edit(_ context: HandleContext, name: String, _ change: (inout EffectControl) -> Void) -> HandleEdit? {
        var result = context.clip
        guard let index = result.effects.index(of: effectID) else { return nil }
        result.effects[index].changeControl(.path, change)
        guard result != context.clip else { return nil }
        return HandleEdit(change: { $0 = result }, readout: name, actionName: name)
    }

    /// The path at the playhead, written as typing in the panel does: a
    /// keyframe there when it is animated.
    private func write(_ path: FreePath, _ located: Located, _ context: HandleContext, readout: String, actionName: String) -> HandleEdit? {
        var result = context.clip
        guard let index = result.effects.index(of: effectID) else { return nil }
        result.effects[index].changeControl(.path) { $0.setPath(path, at: context.sourceTime) }
        return HandleEdit(change: { $0 = result }, readout: readout, actionName: actionName)
    }
}

/// Which of a point's tangents: toward where the path comes in from, or
/// toward where it goes on to.
enum TangentSide: Hashable, Sendable {
    case `in`, out
}

/// How a press on a path's points picks them, the same with the arrow and
/// with the pen (whose Command is the arrow): one modifier, Command, adds
/// a point to the points picked together (see docs/pen-tool.md, "Editing
/// a path").
enum PathPointPicking {
    /// What a press does to the points picked, and what it leaves for its
    /// release to do if it turns out to be a click rather than a drag.
    struct Press: Equatable {
        /// The points picked from the press on, which a drag moves.
        var points: Set<Int>
        /// The points picked if the press is let go without dragging.
        var onClick: Set<Int>
    }

    /// A press on point `index` (nil: on nothing) with `points` picked.
    /// Without Command a press on a point picks it alone, unless it is
    /// picked, when a drag moves them all and a click picks it alone.
    /// With Command a point joins them (a drag then moves them all) or, if
    /// it is picked, a click takes it out; a press on nothing lets them go.
    static func press(on index: Int?, picked points: Set<Int>, command: Bool) -> Press {
        guard let index else { return command ? Press(points: [], onClick: []) : Press(points: points, onClick: points) }
        if command {
            if points.contains(index) { return Press(points: points, onClick: points.subtracting([index])) }
            let joined = points.union([index])
            return Press(points: joined, onClick: joined)
        }
        if points.contains(index) { return Press(points: points, onClick: [index]) }
        return Press(points: [index], onClick: [index])
    }
}
