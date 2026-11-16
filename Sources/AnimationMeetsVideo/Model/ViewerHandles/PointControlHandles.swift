import CoreGraphics
import CoreMedia
import Foundation

/// A round handle for each point control of the effect selected in the
/// effects panel (see docs/viewer-handles.md, "An effect's own handles"):
/// a package's `point` is a position from the middle of the frame in the
/// timeline's pixels, which is exactly a handle. Spotlight's Center, a
/// mask's corners, Twirl's and Zoom Blur's centers get one with no change
/// to their packages; a control opts out with `"handle": false`.
///
/// An effect works in the frame's pixels at its place in the stack, and
/// the Transform effects below it move the picture afterwards, so the
/// handles are mapped through those (`StackFolding.placement(after:)`)
/// and stay on what the effect draws.
struct PointControlHandles: ViewerHandleSet {
    let effectID: UUID

    /// Whether `effect` has a point control the viewer shows a handle for.
    static func applies(to effect: Effect) -> Bool {
        effect.controls.contains { $0.kind.hasViewerHandle }
    }

    /// The effect, its place among the effects the viewer draws, and the
    /// matrix from its coordinates to the frame's after the rest of the
    /// stack; nil when it is off, cut off by Show Up to Here, or under a
    /// Transform that scales the picture to nothing.
    private func located(_ context: HandleContext) -> (effect: Effect, matrix: CGAffineTransform)? {
        Self.locate(effectID, context)
    }

    /// The effect with ID `effectID` among those the viewer draws, and the
    /// matrix from its coordinates to the frame's after the rest of the
    /// stack; the same for any of an effect's own handles.
    static func locate(_ effectID: UUID, _ context: HandleContext) -> (effect: Effect, matrix: CGAffineTransform)? {
        let effects = TransformHandles.shownEffects(context.clip, upTo: context.shownUpTo)
        guard let index = effects.index(of: effectID), effects[index].enabled,
              let matrix = StackFolding.placement(
                  after: index, effects: effects, anchorPoint: context.clip.anchorPoint, at: context.sourceTime, center: context.center
              )
        else { return nil }
        return (effects[index], matrix)
    }

    /// The point controls that have handles, on.
    private static func points(of effect: Effect) -> [EffectControl] {
        effect.controls.filter { $0.enabled && $0.kind.hasViewerHandle }
    }

    /// The handle of the control with ID `id`.
    static func handle(of controlID: UUID) -> HandleID { .named(controlID.uuidString) }

    private static func controlID(of handle: HandleID) -> UUID? {
        guard case .named(let name) = handle else { return nil }
        return UUID(uuidString: name)
    }

    /// Where a point's numbers put it, in the effect's coordinates.
    private static func spot(_ values: [Double], _ context: HandleContext) -> CGPoint {
        guard values.count == 2 else { return context.center }
        return CGPoint(x: context.center.x + values[0], y: context.center.y + values[1])
    }

    func handles(_ context: HandleContext) -> [ViewerHandle] {
        guard !context.isLocked, let found = located(context) else { return [] }
        let effect = found.effect, matrix = found.matrix
        return Self.points(of: effect).map { control in
            let values = control.values(at: context.sourceTime)
            let refusal = Self.driver(of: control.id, effect: effect.id, in: context.clip)
            return ViewerHandle(
                id: Self.handle(of: control.id), place: Self.spot(values, context).applying(matrix), glyph: .round,
                cursor: refusal == nil ? .move : .notAllowed, reach: TransformHandles.handleReach,
                isEnabled: refusal == nil, refusal: refusal, name: control.kind.name,
                value: Self.text(values), hoverText: "\(control.kind.name) \(Self.text(values))"
            )
        }
    }

    func outlines(_ context: HandleContext) -> [ViewerOutline] { [] }

    func area(at point: CGPoint, _ context: HandleContext) -> HandleID? { nil }

    func pivot(of handle: HandleID, _ context: HandleContext) -> CGPoint? { nil }

    private static func text(_ values: [Double]) -> String {
        values.count == 2 ? HandleFormat.pair(values[0], values[1]) : ""
    }

    /// The refusal a point the Keyframing effect drives gives.
    private static func driver(of controlID: UUID, effect effectID: UUID, in clip: TimelineClip) -> HandleRefusal? {
        let target = KeyframingTarget.control(effectID: effectID, controlID: controlID)
        guard let driver = clip.effects.first(where: { $0.keyframing?.target == target }) else { return nil }
        return .driven(keyframingEffectID: driver.id, effectID: effectID, controlID: controlID)
    }

    func refusal(for handle: HandleID, _ context: HandleContext) -> HandleRefusal? {
        guard let id = Self.controlID(of: handle) else { return nil }
        return Self.driver(of: id, effect: effectID, in: context.clip)
    }

    /// The point follows the pointer, in whole pixels of the effect's
    /// coordinates; with Shift kept to the axis the drag is nearer on
    /// screen, with Option a tenth of the pointer's movement, in tenths.
    func edit(_ drag: HandleDrag, _ context: HandleContext) -> HandleEdit? {
        guard let id = Self.controlID(of: drag.handle), let found = located(context),
              let control = found.effect.controls.first(id: id)
        else { return nil }
        let effect = found.effect, matrix = found.matrix
        var delta = drag.delta
        if drag.shift {
            if abs(delta.dx) >= abs(delta.dy) { delta.dy = 0 } else { delta.dx = 0 }
        }
        if drag.option {
            delta.dx *= 0.1
            delta.dy *= 0.1
        }
        // A move on screen as a move in the effect's coordinates.
        let back = matrix.inverted()
        let change = CGPoint(x: delta.dx, y: delta.dy).applying(CGAffineTransform(a: back.a, b: back.b, c: back.c, d: back.d, tx: 0, ty: 0))
        let start = control.values(at: context.sourceTime)
        guard start.count == 2 else { return nil }
        let step = drag.option || drag.fine ? 0.1 : 1
        let moved = [
            ((start[0] + Double(change.x)) / step).rounded() * step,
            ((start[1] + Double(change.y)) / step).rounded() * step,
        ]
        guard moved != start else { return nil }
        return write(moved, to: control, of: effect, context)
    }

    func nudge(_ handle: HandleID, _ direction: NudgeDirection, step: NudgeStep, _ context: HandleContext) -> HandleEdit? {
        guard let id = Self.controlID(of: handle), let effect = located(context)?.effect, let control = effect.controls.first(id: id) else {
            return nil
        }
        let start = control.values(at: context.sourceTime)
        guard start.count == 2 else { return nil }
        let (dx, dy): (Double, Double) = switch direction {
        case .left: (-1, 0)
        case .right: (1, 0)
        case .up: (0, -1)
        case .down: (0, 1)
        }
        let amount = step.multiplier
        return write([start[0] + dx * amount, start[1] + dy * amount], to: control, of: effect, context)
    }

    func reset(_ handle: HandleID, _ context: HandleContext) -> HandleEdit? {
        guard let id = Self.controlID(of: handle), let effect = located(context)?.effect, let control = effect.controls.first(id: id) else {
            return nil
        }
        let fresh = effect.freshControl(control.kind, in: context.frameSize).values(at: context.sourceTime)
        guard fresh != control.values(at: context.sourceTime) else { return nil }
        return write(fresh, to: control, of: effect, context, actionName: "Reset \(control.kind.name)")
    }

    func keyTargets(_ context: HandleContext) -> [HandleKeyTarget] {
        guard let effect = located(context)?.effect else { return [] }
        return Self.points(of: effect).map { control in
            let values = control.values(at: context.sourceTime)
            let name = control.kind.name
            func pixels(_ index: Int) -> String {
                "\(HandleFormat.number(values.indices.contains(index) ? values[index] : 0)) pixels"
            }
            return HandleKeyTarget(handle: Self.handle(of: control.id), name: name, value: Self.text(values), axes: [
                HandleAxis(name: "\(name) X", value: pixels(0), increment: .right, decrement: .left,
                           larger: ("Move 10 pixels right", "Move 10 pixels left")),
                HandleAxis(name: "\(name) Y", value: pixels(1), increment: .down, decrement: .up,
                           larger: ("Move 10 pixels down", "Move 10 pixels up")),
            ])
        }
    }

    /// The point at `values`, written as typing in the panel does: a
    /// keyframe at the playhead when it is animated.
    private func write(
        _ values: [Double], to control: EffectControl, of effect: Effect, _ context: HandleContext, actionName: String? = nil
    ) -> HandleEdit? {
        var result = context.clip
        guard let index = result.effects.index(of: effect.id) else { return nil }
        result.effects[index].changeControl(control.kind) { control in
            for (component, value) in values.enumerated() {
                control.setComponent(component, to: value, at: context.sourceTime)
            }
        }
        let name = control.kind.name
        return HandleEdit(
            change: { $0 = result }, readout: "\(name) \(Self.text(values))", actionName: actionName ?? "Move \(name)"
        )
    }
}
