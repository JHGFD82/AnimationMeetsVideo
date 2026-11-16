import CoreGraphics
import CoreMedia
import Foundation

/// The handles of the shape or text effect selected in the effects panel
/// (see docs/graphic-layers.md, "Editing in the viewer"): its Position as
/// a handle at its middle, a rectangle's or an ellipse's width and height
/// at its right and bottom edges and both at its corner, a rectangle's
/// Corners along its top edge, a polygon's or a star's Radius and
/// Rotation at its first point and a star's Inner Radius at its first
/// notch, and a text block's Wrap Width at the edge its anchor leaves
/// free. They work in the effect's coordinates at its place in the stack,
/// mapped through the Transform effects below it as an effect's points
/// are (`PointControlHandles.locate`), with the shape's outline drawn as a
/// guide. Free paths' vertices wait on free paths in the model.
struct ShapeHandles: ViewerHandleSet {
    let effectID: UUID

    static func applies(to effect: Effect) -> Bool {
        [EffectKind.rectangle, .ellipse, .polygon, .star, .text].contains(effect.kind)
    }

    /// One of the handles.
    enum Part: String, CaseIterable, Sendable {
        case center, width, height, size, corners, radius, inner, wrap

        var name: String {
            switch self {
            case .center: "Position"
            case .width: "Width"
            case .height: "Height"
            case .size: "Size"
            case .corners: "Corners"
            case .radius: "Radius"
            case .inner: "Inner Radius"
            case .wrap: "Wrap Width"
            }
        }

        var handle: HandleID { .named("shape:\(rawValue)") }

        init?(_ handle: HandleID) {
            guard case .named(let name) = handle, name.hasPrefix("shape:"), let part = Part(rawValue: String(name.dropFirst(6))) else {
                return nil
            }
            self = part
        }

        /// The controls a drag of it writes.
        var controls: [ControlKind] {
            switch self {
            case .center: [.shapePosition]
            case .width, .height, .size: [.shapeSize]
            case .corners: [.cornerRadius]
            case .radius: [.radius, .shapeRotation]
            case .inner: [.innerRadius]
            case .wrap: [.wrapWidth]
            }
        }
    }

    /// The shape at the playhead, in the effect's coordinates.
    private struct Shape {
        var effect: Effect
        var matrix: CGAffineTransform
        var middle: CGPoint
        var values: [ControlKind: [Double]]

        func value(_ kind: ControlKind, _ index: Int = 0) -> Double {
            let numbers = values[kind] ?? kind.defaultValues
            return numbers.indices.contains(index) ? numbers[index] : 0
        }

        var size: (width: Double, height: Double) { (value(.shapeSize, 0), value(.shapeSize, 1)) }
    }

    private func located(_ context: HandleContext) -> Shape? {
        guard let found = PointControlHandles.locate(effectID, context), Self.applies(to: found.effect) else { return nil }
        var values: [ControlKind: [Double]] = [:]
        for control in found.effect.controls {
            values[control.kind] = control.enabled ? control.values(at: context.sourceTime) : control.kind.defaultValues
        }
        let offset = values[.shapePosition] ?? [0, 0]
        let middle = CGPoint(x: context.center.x + (offset.first ?? 0), y: context.center.y + (offset.count > 1 ? offset[1] : 0))
        return Shape(effect: found.effect, matrix: found.matrix, middle: middle, values: values)
    }

    /// The parts the shape's kind has.
    private static func parts(of kind: EffectKind) -> [Part] {
        switch kind {
        case .rectangle: [.center, .width, .height, .size, .corners]
        case .ellipse: [.center, .width, .height, .size]
        case .polygon: [.center, .radius]
        case .star: [.center, .radius, .inner]
        default: [.center, .wrap]
        }
    }

    // MARK: Places

    /// The angle of a polygon's first point, in radians, y down: straight
    /// up before its Rotation.
    private static func firstAngle(_ shape: Shape) -> Double {
        shape.value(.shapeRotation) * .pi / 180 - .pi / 2
    }

    /// A text block's frame in the effect's coordinates and which edge its
    /// Wrap Width handle is on (right while its anchor is on the left half);
    /// nil without words, or while it follows a path.
    private static func textBlock(_ shape: Shape, _ context: HandleContext) -> (rect: CGRect, right: Bool, anchor: Double)? {
        guard shape.effect.kind == .text, let setting = TextOutline.Setting(shape.effect, at: context.sourceTime) else { return nil }
        if let path = shape.effect.control(.textOnPath), path.enabled, path.choice == OnOff.on.rawValue { return nil }
        let laid = TextLayout.shared.laid(setting)
        let anchor = setting.anchor.fraction
        let width = Double(laid.size.width), height = Double(laid.size.height)
        let rect = CGRect(
            x: Double(shape.middle.x) - width * anchor.x, y: Double(shape.middle.y) - height * anchor.y,
            width: width, height: height
        )
        return (rect, anchor.x <= 0.5, anchor.x)
    }

    /// Where a part's handle is, in the effect's coordinates.
    private static func place(_ part: Part, _ shape: Shape, _ context: HandleContext) -> CGPoint? {
        let x = Double(shape.middle.x), y = Double(shape.middle.y)
        let (w, h) = shape.size
        switch part {
        case .center: return shape.middle
        case .width: return CGPoint(x: x + w / 2, y: y)
        case .height: return CGPoint(x: x, y: y + h / 2)
        case .size: return CGPoint(x: x + w / 2, y: y + h / 2)
        case .corners:
            let corner = min(shape.value(.cornerRadius), w / 2, h / 2)
            return CGPoint(x: x - w / 2 + max(corner, 0), y: y - h / 2)
        case .radius:
            let angle = firstAngle(shape), r = shape.value(.radius)
            return CGPoint(x: x + r * cos(angle), y: y + r * sin(angle))
        case .inner:
            let count = max(shape.value(.points), 3)
            let angle = firstAngle(shape) + .pi / count, r = shape.value(.innerRadius)
            return CGPoint(x: x + r * cos(angle), y: y + r * sin(angle))
        case .wrap:
            guard let block = textBlock(shape, context) else { return nil }
            return CGPoint(x: block.right ? block.rect.maxX : block.rect.minX, y: block.rect.midY)
        }
    }

    // MARK: The set

    func handles(_ context: HandleContext) -> [ViewerHandle] {
        guard !context.isLocked, let shape = located(context) else { return [] }
        return Self.parts(of: shape.effect.kind).compactMap { part in
            guard let spot = Self.place(part, shape, context) else { return nil }
            let refusal = Self.driver(of: part, shape, context)
            let text = Self.text(of: part, shape)
            return ViewerHandle(
                id: part.handle, place: spot.applying(shape.matrix), glyph: part == .center ? .round : .diamond,
                cursor: refusal == nil ? .move : .notAllowed, reach: TransformHandles.handleReach,
                isEnabled: refusal == nil, refusal: refusal, name: part.name, value: text, hoverText: "\(part.name) \(text)"
            )
        }
    }

    func outlines(_ context: HandleContext) -> [ViewerOutline] {
        guard let shape = located(context) else { return [] }
        var points: [CGPoint] = []
        if shape.effect.kind == .text {
            guard let block = Self.textBlock(shape, context) else { return [] }
            let r = block.rect
            points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        } else if let step = ShapeStep(shape.effect, at: context.sourceTime, center: context.center) {
            points = Self.flattened(step.path)
        }
        guard points.count > 1 else { return [] }
        return [ViewerOutline(points: points.map { $0.applying(shape.matrix) }, isClosed: true, style: .guide)]
    }

    /// A path's points, its curves cut into short lines.
    private static func flattened(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        var last = CGPoint.zero
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint:
                last = e.points[0]
                points.append(last)
            case .addQuadCurveToPoint:
                let c = e.points[0], end = e.points[1]
                for step in 1...8 {
                    let t = CGFloat(step) / 8, u = 1 - t
                    points.append(CGPoint(x: u * u * last.x + 2 * u * t * c.x + t * t * end.x, y: u * u * last.y + 2 * u * t * c.y + t * t * end.y))
                }
                last = end
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], end = e.points[2]
                for step in 1...8 {
                    let t = CGFloat(step) / 8, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    points.append(CGPoint(x: a * last.x + b * c1.x + c * c2.x + d * end.x, y: a * last.y + b * c1.y + c * c2.y + d * end.y))
                }
                last = end
            default:
                break
            }
        }
        return points
    }

    func area(at point: CGPoint, _ context: HandleContext) -> HandleID? { nil }

    func pivot(of handle: HandleID, _ context: HandleContext) -> CGPoint? { nil }

    // MARK: Editing

    func edit(_ drag: HandleDrag, _ context: HandleContext) -> HandleEdit? {
        guard let part = Part(drag.handle), let shape = located(context),
              abs(shape.matrix.a * shape.matrix.d - shape.matrix.b * shape.matrix.c) > 1e-12
        else { return nil }
        var delta = drag.delta
        if drag.shift, part == .center {
            if abs(delta.dx) >= abs(delta.dy) { delta.dy = 0 } else { delta.dx = 0 }
        }
        if drag.option {
            delta.dx *= 0.1
            delta.dy *= 0.1
        }
        let back = shape.matrix.inverted()
        let d = CGPoint(x: delta.dx, y: delta.dy).applying(CGAffineTransform(a: back.a, b: back.b, c: back.c, d: back.d, tx: 0, ty: 0))
        let step = drag.option || drag.fine ? 0.1 : 1
        func rounded(_ value: Double) -> Double { (value / step).rounded() * step }
        let dx = Double(d.x), dy = Double(d.y)
        let (w, h) = shape.size
        var writes: [(ControlKind, [Double])] = []
        switch part {
        case .center:
            writes = [(.shapePosition, [rounded(shape.value(.shapePosition, 0) + dx), rounded(shape.value(.shapePosition, 1) + dy)])]
        case .width:
            writes = [(.shapeSize, [rounded(max(0, w + 2 * dx)), h])]
        case .height:
            writes = [(.shapeSize, [w, rounded(max(0, h + 2 * dy))])]
        case .size:
            if drag.shift, w > 0, h > 0 {
                // In proportion, along the diagonal.
                let length = w * w + h * h
                let factor = max(0, 1 + 2 * (dx * w + dy * h) / length)
                writes = [(.shapeSize, [rounded(w * factor), rounded(h * factor)])]
            } else {
                writes = [(.shapeSize, [rounded(max(0, w + 2 * dx)), rounded(max(0, h + 2 * dy))])]
            }
        case .corners:
            let corner = min(shape.value(.cornerRadius), w / 2, h / 2)
            writes = [(.cornerRadius, [rounded((max(corner, 0) + dx).clamped(between: 0, and: max(0, min(w, h) / 2)))])]
        case .radius:
            guard let start = Self.place(.radius, shape, context) else { return nil }
            let to = CGPoint(x: Double(start.x) + dx - Double(shape.middle.x), y: Double(start.y) + dy - Double(shape.middle.y))
            let radius = rounded(Double(hypot(to.x, to.y)))
            writes = [(.radius, [radius])]
            // Shift keeps the turn.
            if !drag.shift, radius > 0 {
                let was = shape.value(.shapeRotation)
                let wanted = Double(atan2(to.y, to.x)) * 180 / .pi + 90
                var turn = (wanted - was).truncatingRemainder(dividingBy: 360)
                if turn > 180 { turn -= 360 }
                if turn < -180 { turn += 360 }
                writes.append((.shapeRotation, [((was + turn) * 10).rounded() / 10]))
            }
        case .inner:
            let count = max(shape.value(.points), 3)
            let angle = Self.firstAngle(shape) + .pi / count
            let along = dx * cos(angle) + dy * sin(angle)
            writes = [(.innerRadius, [rounded(max(0, shape.value(.innerRadius) + along))])]
        case .wrap:
            guard let block = Self.textBlock(shape, context) else { return nil }
            // The free edge follows the pointer; the anchor holds the rest.
            let width = block.right
                ? Double(block.rect.width) + dx / max(1 - block.anchor, 0.5)
                : Double(block.rect.width) - dx / max(block.anchor, 0.5)
            writes = [(.wrapWidth, [rounded(max(1, width))])]
        }
        return write(writes, part, shape, context)
    }

    func nudge(_ handle: HandleID, _ direction: NudgeDirection, step: NudgeStep, _ context: HandleContext) -> HandleEdit? {
        guard let part = Part(handle), let shape = located(context) else { return nil }
        let amount = step.multiplier
        let (dx, dy): (Double, Double) = switch direction {
        case .left: (-amount, 0)
        case .right: (amount, 0)
        case .up: (0, -amount)
        case .down: (0, amount)
        }
        // → and ↑ make a number bigger, as on the Transform handles; for
        // a turn, → and ↓ are clockwise.
        let more = direction == .right || direction == .up ? amount : -amount
        let (w, h) = shape.size
        let writes: [(ControlKind, [Double])]
        switch part {
        case .center: writes = [(.shapePosition, [shape.value(.shapePosition, 0) + dx, shape.value(.shapePosition, 1) + dy])]
        case .width: writes = [(.shapeSize, [max(0, w + more), h])]
        case .height: writes = [(.shapeSize, [w, max(0, h + more)])]
        case .size: writes = [(.shapeSize, [max(0, w + more), max(0, h + more)])]
        case .corners: writes = [(.cornerRadius, [max(0, shape.value(.cornerRadius) + more)])]
        case .radius:
            if direction == .left || direction == .right {
                let turn: Double = switch step {
                case .normal: 1
                case .large: 15
                case .fine: 0.1
                }
                writes = [(.shapeRotation, [shape.value(.shapeRotation) + (direction == .right ? turn : -turn)])]
            } else {
                writes = [(.radius, [max(0, shape.value(.radius) + more)])]
            }
        case .inner: writes = [(.innerRadius, [max(0, shape.value(.innerRadius) + more)])]
        case .wrap:
            guard let block = Self.textBlock(shape, context) else { return nil }
            writes = [(.wrapWidth, [max(1, Double(block.rect.width) + more)])]
        }
        return write(writes, part, shape, context)
    }

    func reset(_ handle: HandleID, _ context: HandleContext) -> HandleEdit? {
        guard let part = Part(handle), let shape = located(context) else { return nil }
        let writes = part.controls.map { kind in
            (kind, shape.effect.freshControl(kind, in: context.frameSize).values(at: context.sourceTime))
        }
        return write(writes, part, shape, context, actionName: "Reset \(part.name)")
    }

    /// The numbers written as typing in the panel does (a keyframe at the
    /// playhead where animated), each control switched on; a linked Size
    /// keeps its proportion when one number is dragged. Nil when nothing
    /// changes.
    private func write(
        _ writes: [(ControlKind, [Double])], _ part: Part, _ shape: Shape, _ context: HandleContext, actionName: String? = nil
    ) -> HandleEdit? {
        var result = context.clip
        guard let index = result.effects.index(of: effectID) else { return nil }
        for (kind, values) in writes {
            guard result.effects[index].control(kind) != nil || shape.effect.kind.controlKinds.contains(kind) else { continue }
            if result.effects[index].control(kind) == nil { result.effects[index].addControl(kind) }
            result.effects[index].changeControl(kind) { control in
                control.enabled = true
                let before = control.values(at: context.sourceTime)
                let changed = values.indices.filter { !before.indices.contains($0) || before[$0] != values[$0] }
                if control.linked, kind.isLinkable, changed.count == 1 {
                    // One number dragged: the other follows, as in the panel.
                    control.setComponent(changed[0], to: values[changed[0]], at: context.sourceTime)
                } else {
                    let linked = control.linked
                    control.linked = false
                    for component in changed { control.setComponent(component, to: values[component], at: context.sourceTime) }
                    control.linked = linked
                }
            }
        }
        guard result != context.clip else { return nil }
        var after = shape
        if let edited = result.effects.first(id: effectID) {
            for control in edited.controls { after.values[control.kind] = control.values(at: context.sourceTime) }
        }
        return HandleEdit(change: { $0 = result }, readout: "\(part.name) \(Self.text(of: part, after))", actionName: actionName ?? "Change \(part.name)")
    }

    /// A part's value as the readout says it.
    private static func text(of part: Part, _ shape: Shape) -> String {
        let (w, h) = shape.size
        switch part {
        case .center: return HandleFormat.pair(shape.value(.shapePosition, 0), shape.value(.shapePosition, 1))
        case .width: return HandleFormat.number(w) + " px"
        case .height: return HandleFormat.number(h) + " px"
        case .size: return "\(HandleFormat.number(w)) \u{00D7} \(HandleFormat.number(h)) px"
        case .corners: return HandleFormat.number(shape.value(.cornerRadius)) + " px"
        case .radius: return "\(HandleFormat.number(shape.value(.radius))) px, \(HandleFormat.degrees(shape.value(.shapeRotation)))"
        case .inner: return HandleFormat.number(shape.value(.innerRadius)) + " px"
        case .wrap:
            let width = shape.value(.wrapWidth)
            return width > 0 ? HandleFormat.number(width) + " px" : "None"
        }
    }

    func refusal(for handle: HandleID, _ context: HandleContext) -> HandleRefusal? {
        guard let part = Part(handle), let shape = located(context) else { return nil }
        return Self.driver(of: part, shape, context)
    }

    private static func driver(of part: Part, _ shape: Shape, _ context: HandleContext) -> HandleRefusal? {
        for kind in part.controls {
            guard let control = shape.effect.control(kind) else { continue }
            let target = KeyframingTarget.control(effectID: shape.effect.id, controlID: control.id)
            if let driver = context.clip.effects.first(where: { $0.keyframing?.target == target }) {
                return .driven(keyframingEffectID: driver.id, effectID: shape.effect.id, controlID: control.id)
            }
        }
        return nil
    }

    func keyTargets(_ context: HandleContext) -> [HandleKeyTarget] {
        guard let shape = located(context) else { return [] }
        return Self.parts(of: shape.effect.kind).compactMap { part in
            if part == .size { return nil }
            if part == .wrap, Self.textBlock(shape, context) == nil { return nil }
            let text = Self.text(of: part, shape)
            func pixels(_ value: Double) -> String { "\(HandleFormat.number(value)) pixels" }
            let axes: [HandleAxis] = switch part {
            case .center: [
                HandleAxis(name: "Position X", value: pixels(shape.value(.shapePosition, 0)), increment: .right, decrement: .left,
                           larger: ("Move 10 pixels right", "Move 10 pixels left")),
                HandleAxis(name: "Position Y", value: pixels(shape.value(.shapePosition, 1)), increment: .down, decrement: .up,
                           larger: ("Move 10 pixels down", "Move 10 pixels up")),
            ]
            case .radius: [
                HandleAxis(name: "Radius", value: pixels(shape.value(.radius)), increment: .up, decrement: .down,
                           larger: ("Larger by 10 pixels", "Smaller by 10 pixels")),
                HandleAxis(name: "Rotation", value: "\(HandleFormat.number(shape.value(.shapeRotation))) degrees", increment: .right,
                           decrement: .left, larger: ("Turn 15 degrees clockwise", "Turn 15 degrees counterclockwise")),
            ]
            default: [
                HandleAxis(name: part.name, value: text, increment: .up, decrement: .down,
                           larger: ("Larger by 10 pixels", "Smaller by 10 pixels")),
            ]
            }
            return HandleKeyTarget(handle: part.handle, name: part.name, value: text, axes: axes)
        }
    }
}
