import CoreGraphics
import CoreMedia
import Foundation

/// The handles over a visual clip that move, scale, turn and fade it and
/// move its anchor point (see docs/viewer-handles.md, "Transform
/// handles"). They edit the Transform effect the effects panel would: the
/// one picked there, or the last one in the stack, or one they add.
///
/// Every edit is solved from the fold of the stack itself
/// (`StackFolding.fold`), with the target's controls set to trial values,
/// so a handle stays under the pointer whatever else is in the stack.
struct TransformHandles: ViewerHandleSet {
    /// What a drag or a key changes, as the arrows pick it (Tab).
    enum Part: Int, CaseIterable, Sendable {
        case position, scale, rotation, anchor, opacity

        var name: String {
            switch self {
            case .position: "Position"
            case .scale: "Scale"
            case .rotation: "Rotation"
            case .anchor: "Anchor"
            case .opacity: "Opacity"
            }
        }

        /// The handle whose nudge changes it.
        var handle: HandleID {
            switch self {
            case .position: .move
            case .scale: .scale(.bottomRight)
            case .rotation: .rotate(.topRight)
            case .anchor: .anchor
            case .opacity: .opacity
            }
        }

        init?(_ handle: HandleID) {
            switch handle {
            case .move: self = .position
            case .scale: self = .scale
            case .rotate: self = .rotation
            case .anchor: self = .anchor
            case .opacity: self = .opacity
            case .named: return nil
            }
        }

        /// The control it writes; the anchor is the clip's own.
        var control: ControlKind? {
            switch self {
            case .position: .position
            case .scale: .scale
            case .rotation: .rotation
            case .opacity: .opacity
            case .anchor: nil
            }
        }

        var actionName: String {
            switch self {
            case .position: "Move"
            case .scale: "Scale"
            case .rotation: "Rotate"
            case .anchor: "Move Anchor Point"
            case .opacity: "Change Opacity"
            }
        }
    }

    // Sizes in view points.
    static let handleSize = 8.0
    static let handleReach = 6.0
    static let rotationReach = 24.0
    /// An edge shorter than this on screen has no middle handle.
    static let shortestEdge = 32.0
    /// Nearer the anchor than this a scale handle has no lever, and a turn
    /// holds its angle.
    static let leverMinimum = 10.0
    /// How near the anchor must come to one of the box's points to catch on it.
    static let anchorCatch = 8.0

    // MARK: The stack

    /// The effects the handles see: the stack, cut short by Show Up to Here.
    static func shownEffects(_ clip: TimelineClip, upTo effectID: UUID?) -> [Effect] {
        guard let effectID, let index = clip.effects.index(of: effectID) else { return clip.effects }
        return Array(clip.effects.prefix(index + 1))
    }

    /// Where all the clip's Transform effects together put its picture.
    static func fold(_ clip: TimelineClip, _ context: HandleContext) -> FoldedPlacement {
        StackFolding.fold(
            effects: shownEffects(clip, upTo: context.shownUpTo), anchorPoint: clip.anchorPoint,
            at: context.sourceTime, center: context.center
        )
    }

    /// The Transform effect a drag edits, if the clip has one that is on:
    /// the one picked in the effects panel, or else the last, the one
    /// nearest the finished picture. Among the effects the viewer draws.
    static func targetIndex(in clip: TimelineClip, _ context: HandleContext) -> Int? {
        let shown = shownEffects(clip, upTo: context.shownUpTo)
        if let selected = context.selectedEffectID, let index = shown.index(of: selected),
           shown[index].kind == .transform, shown[index].enabled {
            return index
        }
        return shown.lastIndex { $0.kind == .transform && $0.enabled }
    }

    /// Where a Transform a drag adds goes: at the end of the stack, above
    /// the Blending effects that end it, among those the viewer draws.
    static func insertionIndex(in clip: TimelineClip, _ context: HandleContext) -> Int {
        let shown = shownEffects(clip, upTo: context.shownUpTo)
        var index = shown.count
        while index > 0, shown[index - 1].kind == .blending { index -= 1 }
        // Past the effect Show Up to Here stops at, it wouldn't be seen:
        // it goes just above it.
        if shown.count < clip.effects.count, index == shown.count, index > 0 { index -= 1 }
        return index
    }

    /// A new Transform for the clip, named as one added from the library
    /// is. The canvas makes it once, when a drag begins, so each step of
    /// the drag adds the same effect.
    static func newTransform(for clip: TimelineClip) -> Effect {
        Effect.make(.transform, among: clip.effects)
    }

    /// The clip with its target ready for `kind`: added if it has none,
    /// the control put back if it was deleted and switched on if off.
    static func prepared(_ clip: TimelineClip, _ context: HandleContext, for kind: ControlKind) -> (clip: TimelineClip, index: Int) {
        var clip = clip
        let index: Int
        if let existing = targetIndex(in: clip, context) {
            index = existing
        } else {
            index = insertionIndex(in: clip, context)
            clip.effects.insert(context.newTransform ?? newTransform(for: clip), at: index)
        }
        if clip.effects[index].control(kind) == nil { clip.effects[index].addControl(kind) }
        clip.effects[index].changeControl(kind) { $0.enabled = true }
        return (clip, index)
    }

    /// A control's numbers at the playhead, or its defaults when the target
    /// is missing, lacks it or has it off.
    static func values(_ kind: ControlKind, in clip: TimelineClip, at index: Int?, _ context: HandleContext) -> [Double] {
        guard let index, clip.effects.indices.contains(index), let control = clip.effects[index].control(kind), control.enabled else {
            return kind.defaultValues
        }
        return control.values(at: context.sourceTime)
    }

    /// The clip with the target's control set to `values`, for a trial fold.
    private static func trying(_ kind: ControlKind, _ values: [Double], in clip: TimelineClip, at index: Int, _ context: HandleContext) -> TimelineClip {
        var clip = clip
        clip.effects[index].changeControl(kind) { $0.number.set(ComponentValue(values: values), at: context.sourceTime) }
        return clip
    }

    /// Writes `values` to the target's control at the playhead, as typing
    /// in the panel does: a keyframe there when it is animated. The link
    /// is switched off when the numbers are to go apart.
    private static func write(
        _ kind: ControlKind, _ values: [Double], into clip: inout TimelineClip, at index: Int, unlinking: Bool = false, _ context: HandleContext
    ) {
        clip.effects[index].changeControl(kind) { control in
            let linked = control.linked
            control.linked = false
            for (component, value) in values.enumerated() {
                control.setComponent(component, to: value, at: context.sourceTime)
            }
            control.linked = unlinking ? false : linked
        }
    }

    /// The refusal a control the Keyframing effect drives gives, if one does.
    static func driver(of kind: ControlKind, in clip: TimelineClip, at index: Int?) -> HandleRefusal? {
        guard let index, clip.effects.indices.contains(index), let control = clip.effects[index].control(kind) else { return nil }
        let effectID = clip.effects[index].id
        let target = KeyframingTarget.control(effectID: effectID, controlID: control.id)
        guard let driver = clip.effects.first(where: { $0.keyframing?.target == target }) else { return nil }
        return .driven(keyframingEffectID: driver.id, effectID: effectID, controlID: control.id)
    }

    // MARK: The box

    /// The rectangle round the clip's picture before its stack, in the
    /// frame's pixels: footage and stills fitted into the frame and
    /// centered (`pictureSize` is their size as shown, rotation applied,
    /// nil while it isn't known), a nested timeline's frame fitted the
    /// same way, and the rectangle round what a graphic clip's shapes
    /// draw (strokes left out), or the frame when they draw nothing.
    static func pictureRect(
        of clip: TimelineClip, in project: EditingProject, frameSize: CGSize, pictureSize: CGSize?, at sourceTime: CMTime
    ) -> CGRect {
        let frame = CGRect(origin: .zero, size: frameSize)
        func fitted(_ size: CGSize) -> CGRect {
            CGRect(origin: .zero, size: size).applying(.fitting(size, into: frameSize))
        }
        switch clip.source {
        case .media:
            return pictureSize.map(fitted) ?? frame
        case .timeline(let id):
            return project.timeline(id: id).map { fitted($0.frameSize) } ?? frame
        case .graphic:
            let center = CGPoint(x: frameSize.width / 2, y: frameSize.height / 2)
            return shapesRect(clip.effects, at: sourceTime, center: center) ?? frame
        case .adjustment:
            return frame
        }
    }

    /// The rectangle round what the shapes in `effects` draw at `time`.
    static func shapesRect(_ effects: [Effect], at time: CMTime, center: CGPoint) -> CGRect? {
        var union: CGRect?
        for effect in effects where effect.enabled && effect.kind.drawsShape {
            guard let shape = ShapeStep(effect, at: time, center: center) else { continue }
            let box = shape.path.boundingBoxOfPath
            guard !box.isNull, box.width > 0 || box.height > 0 else { continue }
            union = union.map { $0.union(box) } ?? box
        }
        return union
    }

    /// The box's corners on screen, clockwise from the top left.
    static func corners(_ placement: FoldedPlacement, _ rect: CGRect) -> [CGPoint] {
        [BoxPoint.topLeft, .topRight, .bottomRight, .bottomLeft].map { $0.point(in: rect).applying(placement.matrix) }
    }

    /// Where one of the box's nine points is on screen.
    static func screen(_ point: BoxPoint, _ placement: FoldedPlacement, _ rect: CGRect) -> CGPoint {
        point.point(in: rect).applying(placement.matrix)
    }

    // MARK: Reading

    /// The numbers the handles change, as the effects panel shows them.
    struct Reading: Equatable {
        var position: [Double]
        var scale: [Double]
        var rotation: Double
        var anchor: Vector2
        var opacity: Double
    }

    static func reading(_ context: HandleContext) -> Reading {
        let clip = context.clip
        let index = targetIndex(in: clip, context)
        return Reading(
            position: values(.position, in: clip, at: index, context),
            scale: values(.scale, in: clip, at: index, context),
            rotation: values(.rotation, in: clip, at: index, context).first ?? 0,
            anchor: clip.anchorPoint.value(at: context.sourceTime),
            opacity: values(.opacity, in: clip, at: index, context).first ?? 100
        )
    }

    /// A part's value as the readout and VoiceOver say it.
    static func text(of part: Part, _ reading: Reading) -> String {
        switch part {
        case .position: HandleFormat.pair(reading.position.first ?? 0, reading.position.last ?? 0)
        case .scale: HandleFormat.scale(reading.scale)
        case .rotation: HandleFormat.degrees(reading.rotation)
        case .anchor: HandleFormat.pair(reading.anchor.x, reading.anchor.y)
        case .opacity: HandleFormat.percent(reading.opacity)
        }
    }

    // MARK: Handles

    func handles(_ context: HandleContext) -> [ViewerHandle] {
        guard !context.isLocked else { return [] }
        let clip = context.clip
        let placement = Self.fold(clip, context)
        let rect = context.pictureRect
        let index = Self.targetIndex(in: clip, context)
        let reading = Self.reading(context)
        let anchor = placement.anchor
        let middle = Self.screen(.center, placement, rect)
        let corners = Self.corners(placement, rect)
        let lever = context.pixels(Self.leverMinimum)
        let turn = atan2(corners[1].y - corners[0].y, corners[1].x - corners[0].x)

        let scaleRefusal = Self.driver(of: .scale, in: clip, at: index)
        let rotationRefusal = Self.driver(of: .rotation, in: clip, at: index)
        // How far the scale handles move for each percent of either number.
        let (prepared, preparedIndex) = Self.prepared(clip, context, for: .scale)
        let scale = Self.values(.scale, in: prepared, at: preparedIndex, context)
        let columnsAt = Self.scaleColumns(prepared, preparedIndex, scale, context)

        var scaleHandles: [ViewerHandle] = []
        var rotationZones: [ViewerHandle] = []
        for point in BoxPoint.rim {
            let place = Self.screen(point, placement, rect)
            if point.isEdge, !Self.edgeIsLongEnough(point, placement, rect, context) { continue }
            let direction = atan2(place.y - middle.y, place.x - middle.x)
            var enabled = scaleRefusal == nil
            let columns = columnsAt(point)
            if let axis = point.axis {
                // An edge level with the anchor has nothing to pull against.
                let column = axis == 0 ? columns.x : columns.y
                if Double(hypot(column.dx, column.dy)) * abs(scale[axis]) < lever { enabled = false }
            } else if Double(hypot(place.x - anchor.x, place.y - anchor.y)) < lever {
                enabled = false
            }
            scaleHandles.append(ViewerHandle(
                id: .scale(point), place: place, glyph: .square, angle: turn,
                cursor: scaleRefusal == nil ? .resize(angle: direction) : .notAllowed, reach: Self.handleReach,
                isEnabled: enabled, refusal: scaleRefusal, name: "Scale, \(point.name)",
                value: Self.text(of: .scale, reading), isPivot: true
            ))
            rotationZones.append(ViewerHandle(
                id: .rotate(point), place: place, glyph: .none,
                cursor: rotationRefusal == nil ? .rotate(angle: direction) : .notAllowed,
                zone: HandleZone(inner: Self.handleReach, outer: Self.rotationReach, excluding: corners),
                isEnabled: rotationRefusal == nil, refusal: rotationRefusal, name: "Rotation, \(point.name)",
                value: Self.text(of: .rotation, reading), isPivot: true
            ))
        }
        let anchorText = Self.text(of: .anchor, reading)
        let anchorHandle = ViewerHandle(
            id: .anchor, place: anchor, glyph: .crosshair, cursor: .crosshair, reach: Self.handleReach,
            isEnabled: Self.canMoveAnchor(placement), name: "Anchor Point", value: anchorText,
            hoverText: "Anchor \(anchorText)"
        )
        return scaleHandles + [anchorHandle] + rotationZones
    }

    func outlines(_ context: HandleContext) -> [ViewerOutline] {
        let placement = Self.fold(context.clip, context)
        return [ViewerOutline(points: Self.corners(placement, context.pictureRect), isClosed: true, style: .box)]
    }

    func area(at point: CGPoint, _ context: HandleContext) -> HandleID? {
        let placement = Self.fold(context.clip, context)
        return HandleHitTest.contains(Self.corners(placement, context.pictureRect), point) ? .move : nil
    }

    func pivot(of handle: HandleID, _ context: HandleContext) -> CGPoint? {
        guard case .rotate = handle else { return nil }
        return Self.fold(context.clip, context).anchor
    }

    /// Whether an edge is long enough on screen for its middle handle.
    private static func edgeIsLongEnough(_ point: BoxPoint, _ placement: FoldedPlacement, _ rect: CGRect, _ context: HandleContext) -> Bool {
        let ends: (BoxPoint, BoxPoint) = switch point {
        case .top: (.topLeft, .topRight)
        case .bottom: (.bottomLeft, .bottomRight)
        case .left: (.topLeft, .bottomLeft)
        default: (.topRight, .bottomRight)
        }
        let a = screen(ends.0, placement, rect), b = screen(ends.1, placement, rect)
        return Double(hypot(b.x - a.x, b.y - a.y)) >= context.pixels(shortestEdge)
    }

    /// Whether the picture has an area on screen, so moving the anchor
    /// while keeping it still has an answer.
    private static func canMoveAnchor(_ placement: FoldedPlacement) -> Bool {
        let m = placement.matrix
        return abs(m.a * m.d - m.b * m.c) > 1e-9
    }

    /// How a box point moves on screen for one percent more of Scale's x,
    /// and of its y.
    private static func scaleColumns(
        _ clip: TimelineClip, _ index: Int, _ scale: [Double], _ context: HandleContext
    ) -> (BoxPoint) -> (x: CGVector, y: CGVector) {
        let base = fold(clip, context).matrix
        let moreX = fold(trying(.scale, [scale[0] + 1, scale[1]], in: clip, at: index, context), context).matrix
        let moreY = fold(trying(.scale, [scale[0], scale[1] + 1], in: clip, at: index, context), context).matrix
        let rect = context.pictureRect
        return { point in
            let spot = point.point(in: rect)
            let here = spot.applying(base)
            return (difference(spot.applying(moreX), here), difference(spot.applying(moreY), here))
        }
    }

    // MARK: Dragging

    func edit(_ drag: HandleDrag, _ context: HandleContext) -> HandleEdit? {
        switch drag.handle {
        case .move: Self.moveEdit(drag, context)
        case .scale(let point): Self.scaleEdit(point, drag, context)
        case .rotate(let point): Self.rotationEdit(point, drag, context)
        case .anchor: Self.anchorEdit(drag, context)
        case .opacity: Self.opacityEdit(drag, context)
        case .named: nil
        }
    }

    /// Inside the box: Position follows the pointer, in whole pixels; with
    /// Shift kept to the axis the drag is nearer.
    private static func moveEdit(_ drag: HandleDrag, _ context: HandleContext) -> HandleEdit? {
        var delta = drag.delta
        if drag.shift {
            if abs(delta.dx) >= abs(delta.dy) { delta.dy = 0 } else { delta.dx = 0 }
        }
        let (clip, index) = prepared(context.clip, context, for: .position)
        let start = values(.position, in: clip, at: index, context)
        guard start.count == 2 else { return nil }
        let base = fold(clip, context).matrix
        // The spot of the picture that was grabbed.
        let grabbed = canInvert(base) ? drag.start.applying(base.inverted()) : BoxPoint.center.point(in: context.pictureRect)
        let here = grabbed.applying(base)
        let moreX = grabbed.applying(fold(trying(.position, [start[0] + 1, start[1]], in: clip, at: index, context), context).matrix)
        let moreY = grabbed.applying(fold(trying(.position, [start[0], start[1] + 1], in: clip, at: index, context), context).matrix)
        guard let change = solve(difference(moreX, here), difference(moreY, here), delta) else { return nil }
        let moved = [(start[0] + change.0).rounded(), (start[1] + change.1).rounded()]
        guard moved != start else { return nil }
        var result = clip
        write(.position, moved, into: &result, at: index, context)
        return HandleEdit(change: { $0 = result }, readout: HandleFormat.pair(moved[0], moved[1], digits: 0), actionName: Part.position.actionName)
    }

    /// A scale handle: about the anchor, so only Scale changes. A corner is
    /// proportional, free with Shift; an edge changes its one number, both
    /// in proportion with Shift.
    private static func scaleEdit(_ point: BoxPoint, _ drag: HandleDrag, _ context: HandleContext) -> HandleEdit? {
        let (clip, index) = prepared(context.clip, context, for: .scale)
        let start = values(.scale, in: clip, at: index, context)
        guard start.count == 2 else { return nil }
        let columns = scaleColumns(clip, index, start, context)(point)
        let delta = drag.delta
        let proportional = point.isCorner ? !drag.shift : drag.shift
        var scaled = start
        if proportional {
            // Along the line from the anchor through the handle.
            let along = CGVector(
                dx: columns.x.dx * CGFloat(start[0]) + columns.y.dx * CGFloat(start[1]),
                dy: columns.x.dy * CGFloat(start[0]) + columns.y.dy * CGFloat(start[1])
            )
            let length = dot(along, along)
            guard length > 1e-12 else { return nil }
            let factor = 1 + dot(delta, along) / length
            scaled = [start[0] * factor, start[1] * factor]
        } else if let axis = point.axis {
            let column = axis == 0 ? columns.x : columns.y
            let length = dot(column, column)
            guard length > 1e-12 else { return nil }
            scaled[axis] += dot(delta, column) / length
        } else if let change = solve(columns.x, columns.y, delta) {
            scaled = [start[0] + change.0, start[1] + change.1]
        } else {
            // Level with the anchor on one axis: what the other can do.
            for (axis, column) in [columns.x, columns.y].enumerated() {
                let length = dot(column, column)
                if length > 1e-12 { scaled[axis] += dot(delta, column) / length }
            }
        }
        scaled = scaled.map { ($0 * 10).rounded() / 10 }
        guard scaled != start else { return nil }
        let unlinking = !proportional && scaled[0] != scaled[1] || point.axis != nil && !drag.shift
        var result = clip
        write(.scale, scaled, into: &result, at: index, unlinking: unlinking, context)
        return HandleEdit(change: { $0 = result }, readout: HandleFormat.scale(scaled), actionName: Part.scale.actionName)
    }

    /// A rotation zone: Rotation follows the pointer round the anchor, the
    /// turns past a full one kept; with Shift the value snaps to 15°.
    private static func rotationEdit(_ point: BoxPoint, _ drag: HandleDrag, _ context: HandleContext) -> HandleEdit? {
        let (clip, index) = prepared(context.clip, context, for: .rotation)
        let start = values(.rotation, in: clip, at: index, context).first ?? 0
        let placement = fold(clip, context)
        // Which way the picture turns on screen for more Rotation: the
        // other way on a flipped clip.
        let spot = point.point(in: context.pictureRect)
        let here = spot.applying(placement.matrix)
        let turned = spot.applying(fold(trying(.rotation, [start + 1], in: clip, at: index, context), context).matrix)
        let pivot = placement.anchor
        let from = difference(here, pivot), to = difference(turned, pivot)
        let cross = Double(from.dx * to.dy - from.dy * to.dx)
        let sign: Double = cross < 0 ? -1 : 1
        var value = start + drag.swept * 180 / .pi * sign
        value = drag.shift ? (value / 15).rounded() * 15 : (value * 10).rounded() / 10
        guard value != start else { return nil }
        var result = clip
        write(.rotation, [value], into: &result, at: index, context)
        return HandleEdit(change: { $0 = result }, readout: HandleFormat.degrees(value), actionName: Part.rotation.actionName)
    }

    /// The opacity chip: a point of drag sideways for 1%, ten with Shift,
    /// a tenth with Option.
    private static func opacityEdit(_ drag: HandleDrag, _ context: HandleContext) -> HandleEdit? {
        let points = Double(drag.now.x - drag.start.x) / max(context.pixelsPerPoint, 1e-9)
        let pace = drag.shift ? 10.0 : drag.option ? 0.1 : 1
        return opacity(by: points * pace, fine: drag.option, context)
    }

    private static func opacity(by change: Double, fine: Bool, _ context: HandleContext) -> HandleEdit? {
        let (clip, index) = prepared(context.clip, context, for: .opacity)
        let start = values(.opacity, in: clip, at: index, context).first ?? 100
        var value = (start + change).clamped(between: 0, and: 100)
        value = fine ? (value * 10).rounded() / 10 : value.rounded()
        guard value != start else { return nil }
        var result = clip
        write(.opacity, [value], into: &result, at: index, context)
        return HandleEdit(change: { $0 = result }, readout: HandleFormat.percent(value), actionName: Part.opacity.actionName)
    }

    // MARK: The anchor

    /// The crosshair: the anchor point follows the pointer, catching on the
    /// box's nine points, while the picture stays where it is. Shift moves
    /// it ten pixels at a time; Option a tenth of the pointer's movement,
    /// in tenths, without catching.
    private static func anchorEdit(_ drag: HandleDrag, _ context: HandleContext) -> HandleEdit? {
        let placement = fold(context.clip, context)
        var delta = drag.delta
        if drag.option {
            delta.dx *= 0.1
            delta.dy *= 0.1
        }
        var wanted = CGPoint(x: placement.anchor.x + delta.dx, y: placement.anchor.y + delta.dy)
        var caught: BoxPoint?
        if !drag.option {
            let reach = context.pixels(anchorCatch)
            let nearest = BoxPoint.allCases
                .map { ($0, screen($0, placement, context.pictureRect)) }
                .min { hypot($0.1.x - wanted.x, $0.1.y - wanted.y) < hypot($1.1.x - wanted.x, $1.1.y - wanted.y) }
            if let nearest, Double(hypot(nearest.1.x - wanted.x, nearest.1.y - wanted.y)) <= reach {
                wanted = nearest.1
                caught = nearest.0
            }
        }
        guard let solved = anchorPoint(puttingAnchorAt: wanted, context) else { return nil }
        let step = drag.shift ? 10.0 : drag.option ? 0.1 : 1
        let rounded = Vector2(x: (solved.x / step).rounded() * step, y: (solved.y / step).rounded() * step)
        return anchorMove(to: rounded, caught: caught, context)
    }

    /// The anchor point that puts the anchor at `wanted` on screen with the
    /// picture where it is, solved with the target's Position alongside
    /// it. Nil when the picture has no area, so there is no answer.
    static func anchorPoint(puttingAnchorAt wanted: CGPoint, _ context: HandleContext) -> Vector2? {
        let original = context.clip
        let start = original.anchorPoint.value(at: context.sourceTime)
        let placement = fold(original, context)
        guard canMoveAnchor(placement) else { return nil }
        guard targetIndex(in: original, context) != nil else {
            // No Transform is on: the picture doesn't depend on the anchor.
            return Vector2(x: start.x + wanted.x - placement.anchor.x, y: start.y + wanted.y - placement.anchor.y)
        }
        let (clip, index) = prepared(original, context, for: .position)
        let position = values(.position, in: clip, at: index, context)
        guard position.count == 2 else { return nil }
        let corner = BoxPoint.topLeft.point(in: context.pictureRect)
        func measure(_ anchor: Vector2, _ moved: [Double]) -> [Double] {
            var trial = trying(.position, moved, in: clip, at: index, context)
            trial.anchorPoint = AnimatedValue(anchor)
            let folded = fold(trial, context)
            let spot = corner.applying(folded.matrix)
            return [Double(folded.anchor.x), Double(folded.anchor.y), Double(spot.x), Double(spot.y)]
        }
        let base = measure(start, position)
        let trials = [
            measure(Vector2(x: start.x + 1, y: start.y), position),
            measure(Vector2(x: start.x, y: start.y + 1), position),
            measure(start, [position[0] + 1, position[1]]),
            measure(start, [position[0], position[1] + 1]),
        ]
        // Columns: what each unknown does to the four numbers.
        var matrix = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        for (column, trial) in trials.enumerated() {
            for row in 0..<4 { matrix[row][column] = trial[row] - base[row] }
        }
        let wantedChange = [Double(wanted.x) - base[0], Double(wanted.y) - base[1], 0, 0]
        guard let change = solve(matrix, wantedChange) else { return nil }
        return Vector2(x: start.x + change[0], y: start.y + change[1])
    }

    /// The anchor point moved to `anchor` with the picture kept where it
    /// is: the target's Position shifted to make up for it, as a whole
    /// (its one value or every keyframe alike), never keyframed. On a clip
    /// neither scaled nor turned only the anchor changes.
    static func anchorMove(to anchor: Vector2, caught: BoxPoint? = nil, _ context: HandleContext) -> HandleEdit? {
        let original = context.clip
        let start = original.anchorPoint.value(at: context.sourceTime)
        guard anchor != start else { return nil }
        var result = original
        result.anchorPoint.set(anchor, at: context.sourceTime)
        if targetIndex(in: original, context) != nil {
            let corner = BoxPoint.topLeft.point(in: context.pictureRect)
            let was = corner.applying(fold(original, context).matrix)
            let (clip, index) = prepared(original, context, for: .position)
            var moved = clip
            moved.anchorPoint = result.anchorPoint
            let position = values(.position, in: moved, at: index, context)
            if position.count == 2 {
                let now = corner.applying(fold(moved, context).matrix)
                let moreX = corner.applying(fold(trying(.position, [position[0] + 1, position[1]], in: moved, at: index, context), context).matrix)
                let moreY = corner.applying(fold(trying(.position, [position[0], position[1] + 1], in: moved, at: index, context), context).matrix)
                if let shift = solve(difference(moreX, now), difference(moreY, now), difference(was, now)),
                   abs(shift.0) > 1e-6 || abs(shift.1) > 1e-6 {
                    moved.effects[index].changeControl(.position) { $0.number.offset(by: [shift.0, shift.1]) }
                    result = moved
                }
            }
        }
        var readout = "Anchor " + HandleFormat.pair(anchor.x, anchor.y)
        if let caught { readout += " \u{00B7} \(caught.shortName)" }
        return HandleEdit(change: { $0 = result }, readout: readout, actionName: Part.anchor.actionName)
    }

    /// The anchor moved onto one of the box's nine points, the picture kept
    /// still: VoiceOver's Move to Center and Move to *each corner and edge*,
    /// and a double-click on the crosshair (the center).
    static func moveAnchor(to point: BoxPoint, _ context: HandleContext) -> HandleEdit? {
        if point == .center, context.clip.source != .graphic {
            return anchorMove(to: .zero, caught: .center, context)
        }
        let placement = fold(context.clip, context)
        guard let solved = anchorPoint(puttingAnchorAt: screen(point, placement, context.pictureRect), context) else { return nil }
        return anchorMove(to: Vector2(x: solved.x.rounded(), y: solved.y.rounded()), caught: point, context)
    }

    /// The anchor back at the middle of the picture, as a double-click on
    /// the crosshair puts it.
    static func resetAnchor(_ context: HandleContext) -> HandleEdit? {
        anchorMove(to: .zero, caught: .center, context)
    }

    // MARK: Keys

    func nudge(_ handle: HandleID, _ direction: NudgeDirection, step: NudgeStep, _ context: HandleContext) -> HandleEdit? {
        guard let part = Part(handle) else { return nil }
        let (dx, dy): (Double, Double) = switch direction {
        case .left: (-1, 0)
        case .right: (1, 0)
        case .up: (0, -1)
        case .down: (0, 1)
        }
        // → and ↑ make a number bigger; for a turn, → and ↓ are clockwise.
        let more: Double = direction == .right || direction == .up ? 1 : -1
        let amount = step.multiplier
        switch part {
        case .position:
            let (clip, index) = Self.prepared(context.clip, context, for: .position)
            let start = Self.values(.position, in: clip, at: index, context)
            guard start.count == 2 else { return nil }
            let moved = [start[0] + dx * amount, start[1] + dy * amount]
            var result = clip
            Self.write(.position, moved, into: &result, at: index, context)
            return HandleEdit(change: { $0 = result }, readout: HandleFormat.pair(moved[0], moved[1]), actionName: part.actionName)
        case .scale:
            let (clip, index) = Self.prepared(context.clip, context, for: .scale)
            let start = Self.values(.scale, in: clip, at: index, context)
            guard start.count == 2 else { return nil }
            // In proportion, the larger number by the step.
            let largest = max(abs(start[0]), abs(start[1]))
            let scaled = largest > 0
                ? start.map { $0 * (largest + more * amount) / largest }
                : [more * amount, more * amount]
            let rounded = scaled.map { ($0 * 10).rounded() / 10 }
            var result = clip
            Self.write(.scale, rounded, into: &result, at: index, context)
            return HandleEdit(change: { $0 = result }, readout: HandleFormat.scale(rounded), actionName: part.actionName)
        case .rotation:
            let clockwise: Double = direction == .right || direction == .down ? 1 : -1
            let (clip, index) = Self.prepared(context.clip, context, for: .rotation)
            let start = Self.values(.rotation, in: clip, at: index, context).first ?? 0
            let steps: Double = switch step {
            case .normal: 1
            case .large: 15
            case .fine: 0.1
            }
            let value = ((start + clockwise * steps) * 10).rounded() / 10
            var result = clip
            Self.write(.rotation, [value], into: &result, at: index, context)
            return HandleEdit(change: { $0 = result }, readout: HandleFormat.degrees(value), actionName: part.actionName)
        case .anchor:
            let start = context.clip.anchorPoint.value(at: context.sourceTime)
            return Self.anchorMove(to: Vector2(x: start.x + dx * amount, y: start.y + dy * amount), context)
        case .opacity:
            return Self.opacity(by: more * amount, fine: step == .fine, context)
        }
    }

    /// A part back at its default, the picture kept still for the anchor:
    /// VoiceOver's Reset.
    static func reset(_ part: Part, _ context: HandleContext) -> HandleEdit? {
        guard let kind = part.control else { return resetAnchor(context) }
        guard let index = targetIndex(in: context.clip, context), context.clip.effects[index].control(kind) != nil else { return nil }
        let start = values(kind, in: context.clip, at: index, context)
        guard start != kind.defaultValues else { return nil }
        var result = context.clip
        write(kind, kind.defaultValues, into: &result, at: index, context)
        var after = context
        after.clip = result
        return HandleEdit(change: { $0 = result }, readout: text(of: part, reading(after)), actionName: "Reset \(part.name)")
    }
}

// MARK: - Arithmetic

private func difference(_ a: CGPoint, _ b: CGPoint) -> CGVector {
    CGVector(dx: a.x - b.x, dy: a.y - b.y)
}

private func dot(_ a: CGVector, _ b: CGVector) -> Double {
    Double(a.dx * b.dx + a.dy * b.dy)
}

private func canInvert(_ matrix: CGAffineTransform) -> Bool {
    abs(matrix.a * matrix.d - matrix.b * matrix.c) > 1e-12
}

/// The amounts of `a` and `b` that add up to `target`, or nil when they
/// point the same way.
private func solve(_ a: CGVector, _ b: CGVector, _ target: CGVector) -> (Double, Double)? {
    let determinant = Double(a.dx * b.dy - a.dy * b.dx)
    guard abs(determinant) > 1e-12 else { return nil }
    let first = Double(target.dx * b.dy - target.dy * b.dx) / determinant
    let second = Double(a.dx * target.dy - a.dy * target.dx) / determinant
    return (first, second)
}

/// `matrix · x = target` for a square matrix, by elimination with partial
/// pivoting; nil when it is singular.
private func solve(_ matrix: [[Double]], _ target: [Double]) -> [Double]? {
    let n = target.count
    var rows = matrix
    var right = target
    for column in 0..<n {
        guard let pivot = (column..<n).max(by: { abs(rows[$0][column]) < abs(rows[$1][column]) }),
              abs(rows[pivot][column]) > 1e-12
        else { return nil }
        rows.swapAt(column, pivot)
        right.swapAt(column, pivot)
        for row in (column + 1)..<n {
            let factor = rows[row][column] / rows[column][column]
            guard factor != 0 else { continue }
            for k in column..<n { rows[row][k] -= factor * rows[column][k] }
            right[row] -= factor * right[column]
        }
    }
    var result = Array(repeating: 0.0, count: n)
    for row in stride(from: n - 1, through: 0, by: -1) {
        var sum = right[row]
        for k in (row + 1)..<n { sum -= rows[row][k] * result[k] }
        result[row] = sum / rows[row][row]
    }
    return result
}

extension AnimatedValue where Value == ComponentValue {
    /// Every number moved by `delta`, the single value and each keyframe's
    /// alike, keeping their times and eases: the whole of a Position
    /// shifted, so whatever it did it now does from somewhere else.
    mutating func offset(by delta: [Double]) {
        mapValues { value in
            ComponentValue(values: value.values.enumerated().map { index, number in
                number + (delta.indices.contains(index) ? delta[index] : 0)
            })
        }
    }
}
