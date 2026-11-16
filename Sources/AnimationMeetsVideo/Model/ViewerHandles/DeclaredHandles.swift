import CoreGraphics
import CoreMedia
import Foundation

/// The handles and guides an effect package declares in its `viewer` key
/// (see docs/effect-packages.md, "Viewer"), for the effect selected in the
/// effects panel: Spotlight's and the masks' size and angle, the lines
/// joining Corner Mask's points. A handle's place is an expression of the
/// controls; dragging it sets controls, or one part of one, to
/// expressions of where it is dragged. Places are offsets from the middle
/// of the frame in the timeline's pixels, down positive, in the effect's
/// coordinates, mapped through the rest of the stack as point controls
/// are (`PointControlHandles.locate`).
struct DeclaredHandles: ViewerHandleSet {
    let effectID: UUID

    /// Whether `effect`'s package declares any handles or guides.
    static func applies(to effect: Effect) -> Bool {
        guard let viewer = effect.kind.definition.package?.viewer else { return false }
        return !viewer.handles.isEmpty || !viewer.guides.isEmpty
    }

    private struct Located {
        var effect: Effect
        var package: EffectPackage
        var viewer: EffectPackage.Viewer
        var matrix: CGAffineTransform
    }

    private func located(_ context: HandleContext) -> Located? {
        guard let found = PointControlHandles.locate(effectID, context), let package = found.effect.kind.definition.package,
              let viewer = package.viewer
        else { return nil }
        return Located(effect: found.effect, package: package, viewer: viewer, matrix: found.matrix)
    }

    /// What the expressions read: the controls at the playhead, the frame's
    /// size, and while dragging, where to.
    private static func readings(_ located: Located, _ context: HandleContext, effect: Effect? = nil, extra: [String: Double] = [:]) -> ControlReadings {
        let frame = ["frameWidth": Double(context.frameSize.width), "frameHeight": Double(context.frameSize.height), "scale": 1.0]
        return ControlReadings(
            effect: effect ?? located.effect, package: located.package, time: context.sourceTime,
            extra: extra.merging(frame) { given, _ in given }
        )
    }

    /// An offset from the middle of the frame, in the effect's coordinates.
    private static func spot(_ place: (x: Double, y: Double), _ context: HandleContext) -> CGPoint {
        CGPoint(x: context.center.x + place.x, y: context.center.y + place.y)
    }

    static func handle(_ index: Int) -> HandleID { .named("viewer:\(index)") }

    private static func index(of handle: HandleID) -> Int? {
        guard case .named(let name) = handle, name.hasPrefix("viewer:") else { return nil }
        return Int(name.dropFirst("viewer:".count))
    }

    func handles(_ context: HandleContext) -> [ViewerHandle] {
        guard !context.isLocked, let located = located(context) else { return [] }
        let values = Self.readings(located, context)
        return located.viewer.handles.enumerated().map { index, handle in
            let refusal = Self.driver(of: handle, located, context)
            let text = Self.text(of: handle, in: located.effect, at: context.sourceTime)
            return ViewerHandle(
                id: Self.handle(index), place: Self.spot(handle.place.evaluate(values), context).applying(located.matrix),
                glyph: .diamond, cursor: refusal == nil ? .move : .notAllowed, reach: TransformHandles.handleReach,
                isEnabled: refusal == nil, refusal: refusal, name: handle.name, value: text,
                hoverText: "\(handle.name): \(text)"
            )
        }
    }

    func outlines(_ context: HandleContext) -> [ViewerOutline] {
        guard let located = located(context) else { return [] }
        let values = Self.readings(located, context)
        func spot(_ place: EffectPackage.Viewer.Place) -> CGPoint { Self.spot(place.evaluate(values), context) }
        func turned(_ center: CGPoint, _ angle: EffectExpression?) -> (Double, Double) -> CGPoint {
            let radians = (angle?.number(values) ?? 0) * .pi / 180
            let c = cos(radians), s = sin(radians)
            return { x, y in CGPoint(x: center.x + x * c - y * s, y: center.y + x * s + y * c) }
        }
        return located.viewer.guides.map { guide in
            let points: [CGPoint]
            let closed: Bool
            switch guide {
            case .line(let places):
                points = places.map(spot)
                closed = false
            case .polygon(let places):
                points = places.map(spot)
                closed = true
            case .ellipse(let center, let size, let angle):
                let half = size.evaluate(values)
                let at = turned(spot(center), angle)
                points = (0..<48).map { step in
                    let t = Double(step) / 48 * 2 * .pi
                    return at(half.x / 2 * cos(t), half.y / 2 * sin(t))
                }
                closed = true
            case .rectangle(let center, let size, let angle):
                let half = size.evaluate(values)
                let at = turned(spot(center), angle)
                let w = half.x / 2, h = half.y / 2
                points = [at(-w, -h), at(w, -h), at(w, h), at(-w, h)]
                closed = true
            }
            return ViewerOutline(points: points.map { $0.applying(located.matrix) }, isClosed: closed, style: .guide)
        }
    }

    func area(at point: CGPoint, _ context: HandleContext) -> HandleID? { nil }

    func pivot(of handle: HandleID, _ context: HandleContext) -> CGPoint? { nil }

    // MARK: Editing

    /// The handle dragged on screen by the drag's movement: Shift keeps it
    /// to the axis it is nearer, Option takes a tenth of it.
    func edit(_ drag: HandleDrag, _ context: HandleContext) -> HandleEdit? {
        guard let index = Self.index(of: drag.handle), let located = located(context),
              located.viewer.handles.indices.contains(index)
        else { return nil }
        var delta = drag.delta
        if drag.shift {
            if abs(delta.dx) >= abs(delta.dy) { delta.dy = 0 } else { delta.dx = 0 }
        }
        if drag.option {
            delta.dx *= 0.1
            delta.dy *= 0.1
        }
        let back = located.matrix.inverted()
        let moved = CGPoint(x: delta.dx, y: delta.dy).applying(CGAffineTransform(a: back.a, b: back.b, c: back.c, d: back.d, tx: 0, ty: 0))
        return move(index, by: (Double(moved.x), Double(moved.y)), located, context)
    }

    func nudge(_ handle: HandleID, _ direction: NudgeDirection, step: NudgeStep, _ context: HandleContext) -> HandleEdit? {
        guard let index = Self.index(of: handle), let located = located(context), located.viewer.handles.indices.contains(index) else {
            return nil
        }
        let amount = step.multiplier
        let change: (Double, Double) = switch direction {
        case .left: (-amount, 0)
        case .right: (amount, 0)
        case .up: (0, -amount)
        case .down: (0, amount)
        }
        return move(index, by: change, located, context)
    }

    /// Handle `index` moved by `change` in the effect's coordinates, its
    /// sets worked out from the controls as they were.
    private func move(_ index: Int, by change: (Double, Double), _ located: Located, _ context: HandleContext) -> HandleEdit? {
        let handle = located.viewer.handles[index]
        let start = handle.place.evaluate(Self.readings(located, context))
        let to = ["x": start.x + change.0, "y": start.y + change.1]
        let values = Self.readings(located, context, extra: to)
        let settings = handle.sets.compactMap { set -> (EffectPackage.Viewer.Setting, Double)? in
            let value = set.value.number(values)
            return value.isFinite ? (set, value) : nil
        }
        return write(settings, of: handle, located, context)
    }

    func reset(_ handle: HandleID, _ context: HandleContext) -> HandleEdit? {
        guard let index = Self.index(of: handle), let located = located(context), located.viewer.handles.indices.contains(index) else {
            return nil
        }
        let declared = located.viewer.handles[index]
        let settings = declared.sets.map { set -> (EffectPackage.Viewer.Setting, Double) in
            let fresh = located.effect.freshControl(set.control, in: context.frameSize).values(at: context.sourceTime)
            let part = set.component ?? 0
            return (set, fresh.indices.contains(part) ? fresh[part] : 0)
        }
        return write(settings, of: declared, located, context, actionName: "Reset \(declared.name)")
    }

    /// The controls set, as typing in the panel does: each switched on,
    /// and a keyframe at the playhead where it is animated. Nil when
    /// nothing changes.
    private func write(
        _ settings: [(EffectPackage.Viewer.Setting, Double)], of handle: EffectPackage.Viewer.Handle, _ located: Located,
        _ context: HandleContext, actionName: String? = nil
    ) -> HandleEdit? {
        var result = context.clip
        guard let effectIndex = result.effects.index(of: effectID) else { return nil }
        for (set, value) in settings {
            result.effects[effectIndex].changeControl(set.control) { control in
                control.enabled = true
                control.setComponent(set.component ?? 0, to: value, at: context.sourceTime)
            }
        }
        guard result != context.clip else { return nil }
        return HandleEdit(
            change: { $0 = result }, readout: "\(handle.name): \(Self.text(of: handle, in: result.effects[effectIndex], at: context.sourceTime))",
            actionName: actionName ?? "Move \(handle.name)"
        )
    }

    /// What a handle sets, as the panel shows it: "Size 600 × 400 px".
    private static func text(of handle: EffectPackage.Viewer.Handle, in effect: Effect, at time: CMTime) -> String {
        var seen: [ControlKind] = []
        for set in handle.sets where !seen.contains(set.control) { seen.append(set.control) }
        return seen.map { kind in
            let values = effect.control(kind).map { $0.enabled ? $0.values(at: time) : kind.defaultValues } ?? kind.defaultValues
            let numbers = values.map { HandleFormat.number($0) }.joined(separator: " \u{00D7} ")
            return "\(kind.name) \(numbers)\(kind.unit)"
        }
        .joined(separator: ", ")
    }

    func refusal(for handle: HandleID, _ context: HandleContext) -> HandleRefusal? {
        guard let index = Self.index(of: handle), let located = located(context), located.viewer.handles.indices.contains(index) else {
            return nil
        }
        return Self.driver(of: located.viewer.handles[index], located, context)
    }

    /// The refusal a handle gets when a Keyframing effect drives a control
    /// it sets.
    private static func driver(of handle: EffectPackage.Viewer.Handle, _ located: Located, _ context: HandleContext) -> HandleRefusal? {
        for set in handle.sets {
            guard let control = located.effect.control(set.control) else { continue }
            let target = KeyframingTarget.control(effectID: located.effect.id, controlID: control.id)
            if let driver = context.clip.effects.first(where: { $0.keyframing?.target == target }) {
                return .driven(keyframingEffectID: driver.id, effectID: located.effect.id, controlID: control.id)
            }
        }
        return nil
    }

    func keyTargets(_ context: HandleContext) -> [HandleKeyTarget] {
        guard let located = located(context) else { return [] }
        return located.viewer.handles.enumerated().map { index, handle in
            let text = Self.text(of: handle, in: located.effect, at: context.sourceTime)
            var axes: [HandleAxis] = []
            if handle.movesAcross {
                axes.append(HandleAxis(name: "\(handle.name), across", value: text, increment: .right, decrement: .left,
                                       larger: ("Move 10 pixels right", "Move 10 pixels left")))
            }
            if handle.movesDown {
                axes.append(HandleAxis(name: "\(handle.name), down", value: text, increment: .down, decrement: .up,
                                       larger: ("Move 10 pixels down", "Move 10 pixels up")))
            }
            return HandleKeyTarget(handle: Self.handle(index), name: handle.name, value: text, axes: axes)
        }
    }
}
