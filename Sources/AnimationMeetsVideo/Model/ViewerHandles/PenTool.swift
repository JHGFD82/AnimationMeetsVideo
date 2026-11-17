import CoreGraphics
import CoreMedia
import Foundation

/// A path the pen works on: an effect of a clip.
struct PenTarget: Equatable, Sendable {
    var clipID: UUID
    var effectID: UUID
}

/// What the pen keeps between presses (`ViewerCanvasState.pen`; see
/// docs/pen-tool.md, "One step per press"). Whether a path is being drawn
/// is read from the project each time (`PenTool.isDrawing`), so an undo
/// that takes the effect away ends the draw without the pen being told.
struct PenState: Equatable, Sendable {
    /// What a new path becomes when no Path or Path Mask waits for one.
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case shape, mask

        var id: Self { self }

        var name: String {
            switch self {
            case .shape: "Shape"
            case .mask: "Mask"
            }
        }
    }

    /// What a draw added, for Escape to take away.
    enum Added: Equatable, Sendable {
        /// The effect it made, with the layer it made for it, if it made one.
        case effect(layerID: UUID?)
        /// Points it added to a path that was already there, which had
        /// this many.
        case points(from: Int)
    }

    var mode = Mode.shape
    /// The path it last worked on, which it draws on while it is open.
    var target: PenTarget?
    var added: Added?
    /// Return ended the draw: the path stays open, and isn't drawn on.
    var ended = false
}

/// The pen as plain logic (see docs/pen-tool.md): what a press over what
/// does, and the project it gives. The canvas (`PenOverlay`) runs each
/// press as a drag, worked out from the project as it was when the press
/// began, and records it as one undo step.
enum PenTool {
    /// Where things are, for a press: the timeline, the playhead, and what
    /// the timeline and the effects panel have selected.
    struct Setting {
        var timelineID: UUID
        /// The playhead, in the timeline's time.
        var time: CMTime
        var selection: TimelineSelection?
        var selectedEffectID: UUID?
        /// Show Up to Here's effect, if it is on the clip drawn on.
        var shownUpTo: UUID?
        /// Clips a tool has locked.
        var locked: Set<UUID> = []
    }

    // MARK: Finding

    /// The path of `target` where the viewer shows it at the playhead; nil
    /// when the clip isn't under the playhead, or the effect is gone, off
    /// or not a path.
    static func locate(_ target: PenTarget, in project: EditingProject, _ setting: Setting) -> PathHandles.Located? {
        guard let timeline = project.timeline(id: setting.timelineID),
              let clip = project.clipAndLayer(target.clipID, in: setting.timelineID)?.clip,
              clip.enabled, setting.time >= clip.startOffset, setting.time < clip.endOffset
        else { return nil }
        let context = HandleContext(
            clip: clip, sourceTime: clip.sourceTime(atTimelineTime: setting.time), frameSize: timeline.frameSize,
            pictureRect: .zero, selectedEffectID: target.effectID, shownUpTo: setting.shownUpTo
        )
        return PathHandles.locate(target.effectID, context)
    }

    /// Whether the pen's path is being drawn: it is still there, has a
    /// point, and is open, and Return hasn't ended the draw.
    static func isDrawing(_ state: PenState, in project: EditingProject, _ setting: Setting) -> Bool {
        guard !state.ended, let target = state.target, let located = locate(target, in: project, setting) else { return false }
        return !located.path.isEmpty && !located.path.closed
    }

    /// The path the pen works on now: the one being drawn, or else the Path
    /// or Path Mask picked in the effects panel.
    static func current(_ state: PenState, in project: EditingProject, _ setting: Setting) -> (target: PenTarget, located: PathHandles.Located)? {
        if isDrawing(state, in: project, setting), let target = state.target, let located = locate(target, in: project, setting) {
            return (target, located)
        }
        guard let selection = setting.selection, selection.timelineID == setting.timelineID, let effectID = setting.selectedEffectID,
              let effect = project.clipAndLayer(selection.timelineClipID, in: setting.timelineID)?.clip.effect(id: effectID),
              PathHandles.applies(to: effect)
        else { return nil }
        let target = PenTarget(clipID: selection.timelineClipID, effectID: effectID)
        return locate(target, in: project, setting).map { (target, $0) }
    }

    // MARK: What is under the pointer

    enum Hit: Equatable, Sendable {
        case nothing
        case vertex(Int)
        case tangent(Int, TangentSide)
        case segment(Int, t: Double)
    }

    /// What a press at `point` (view points) lands on: with `tangents`, the
    /// ends of the tangents that show first, then a point, then a stretch.
    /// `toView` maps the frame's pixels to view points.
    static func hit(
        _ point: CGPoint, on located: PathHandles.Located?, picked: Int?, tangents: Bool, toView: (CGPoint) -> CGPoint
    ) -> Hit {
        guard let located else { return .nothing }
        let path = located.path
        func distance(_ place: CGPoint) -> Double {
            let view = toView(located.frame(place))
            return hypot(Double(view.x - point.x), Double(view.y - point.y))
        }
        if tangents {
            for index in PathHandles.pointsShowingTangents(of: path, picked: picked) {
                let vertex = path.vertices[index]
                for (side, tangent) in [(TangentSide.out, vertex.outTangent), (.in, vertex.inTangent)] where tangent != .zero {
                    if distance(vertex.point + tangent) <= 6 { return .tangent(index, side) }
                }
            }
        }
        // The nearest point within reach; the last one first, then the
        // first, as they are what a draw clicks on.
        var best: (index: Int, distance: Double)?
        for index in path.vertices.indices {
            let d = distance(path.vertices[index].point)
            if d <= 7, d < (best?.distance ?? .infinity) - 0.01 { best = (index, d) }
        }
        if let best { return .vertex(best.index) }
        // A stretch, within 4 points, measured on screen.
        var nearest: (segment: Int, t: Double, distance: Double)?
        for index in 0..<path.segmentCount {
            for step in 0...64 {
                let t = Double(step) / 64
                let d = distance(path.point(onSegment: index, at: t))
                if d < (nearest?.distance ?? .infinity) { nearest = (index, t, d) }
            }
        }
        if let nearest, nearest.distance <= 4 {
            // Narrowed in the path's own coordinates.
            if let spot = located.toPath(frameSpot(point, toView: toView)),
               let exact = path.nearest(to: spot), exact.segment == nearest.segment {
                return .segment(nearest.segment, t: exact.t)
            }
            return .segment(nearest.segment, t: nearest.t)
        }
        return .nothing
    }

    /// The frame pixel under view point `point`, worked back from `toView`
    /// by two of its values (it is a scale and a shift).
    private static func frameSpot(_ point: CGPoint, toView: (CGPoint) -> CGPoint) -> CGPoint {
        let origin = toView(.zero), unit = toView(CGPoint(x: 1, y: 1))
        let sx = unit.x - origin.x, sy = unit.y - origin.y
        guard abs(sx) > 1e-12, abs(sy) > 1e-12 else { return .zero }
        return CGPoint(x: (point.x - origin.x) / sx, y: (point.y - origin.y) / sy)
    }

    // MARK: What a press does

    enum Action: Equatable, Sendable {
        /// A new point at the end of the path being drawn, or the first of
        /// a new one.
        case place
        /// Closes the path being drawn on its first point.
        case close
        /// The last point of the path being drawn: takes its out tangent
        /// away; a drag pulls a new one.
        case retract
        /// An end of an open path not being drawn: draws on from it.
        case carryOn(Int)
        case remove(Int)
        case insert(segment: Int, t: Double)
        /// Option on a point: a click makes it linear, a drag pulls fresh
        /// mirrored tangents out of it.
        case convert(Int)
        /// Option on a tangent's end: moves it alone, breaking the pair.
        case moveTangent(Int, TangentSide)
        /// Option on a stretch: bends it through the pointer.
        case bend(segment: Int, t: Double)

        /// The pointer that says so.
        var cursor: HandleCursor {
            switch self {
            case .place: .pen(.none)
            case .close: .pen(.ring)
            case .retract: .pen(.caret)
            case .carryOn: .pen(.slash)
            case .remove: .pen(.minus)
            case .insert: .pen(.plus)
            case .convert, .moveTangent, .bend: .convert
            }
        }
    }

    /// What a press on `hit` does, with Option held or not, while `path`
    /// is the one the pen works on and is or isn't being drawn.
    static func action(for hit: Hit, path: FreePath?, drawing: Bool, option: Bool) -> Action {
        let count = path?.vertices.count ?? 0
        switch hit {
        case .nothing:
            return .place
        case .tangent(let index, let side):
            return option ? .moveTangent(index, side) : .place
        case .segment(let segment, let t):
            return option ? .bend(segment: segment, t: t) : .insert(segment: segment, t: t)
        case .vertex(let index):
            if option { return .convert(index) }
            guard let path else { return .place }
            if drawing {
                if index == count - 1 { return .retract }
                if index == 0, count >= 2 { return .close }
                return .remove(index)
            }
            if !path.closed, index == 0 || index == count - 1 { return .carryOn(index) }
            return .remove(index)
        }
    }

    // MARK: A press

    /// A press so far: where it went down and where the pointer is, in the
    /// path's coordinates, and the keys held.
    struct Stroke: Equatable, Sendable {
        var action: Action
        var start: CGPoint
        var pointer: CGPoint
        /// Past the canvas's 3 points of movement: a drag, not a click.
        var dragged = false
        /// Shift as the press went down, which keeps a new point on a
        /// multiple of 45° from the one before.
        var shiftAtPress = false
        /// Shift now, which keeps a tangent on a multiple of 45°.
        var shift = false
        var option = false
        /// The in tangent kept since Option went down mid-drag.
        private(set) var keptIn: CGVector?
        /// How far Space has moved the point being placed.
        private(set) var moved = CGVector.zero
        private var movedBefore = CGVector.zero
        /// Where the pointer was as Space went down, and the out tangent
        /// then, kept while Space is held.
        private var spaceFrom: CGPoint?
        private var heldOut: CGVector?

        init(action: Action, at start: CGPoint, shift: Bool = false, option: Bool = false) {
            self.action = action
            self.start = start
            pointer = start
            shiftAtPress = shift
            self.shift = shift
            self.option = option
        }

        var isSpaceDown: Bool { spaceFrom != nil }

        /// The pointer moved to `place` (path coordinates).
        mutating func move(to place: CGPoint) {
            pointer = place
            if let spaceFrom { moved = movedBefore + (place - spaceFrom) }
        }

        /// Where the point being placed is so far: where the press went
        /// down, as far as Space has moved it.
        var anchor: CGPoint { start + moved }

        /// Option went down or up mid-drag: going down, the in tangent
        /// stays where it is from then on (a cusp), and stays so.
        mutating func setOption(_ down: Bool) {
            if down, !option, dragged, keptIn == nil {
                keptIn = PenTool.tenths(-(heldOut ?? (pointer - anchor)))
            }
            option = down
        }

        /// Space went down or up mid-drag: while it is held the pointer
        /// moves the point, tangents and all.
        mutating func setSpace(_ down: Bool) {
            if down, spaceFrom == nil {
                spaceFrom = pointer
                heldOut = dragged ? pointer - anchor : .zero
            } else if !down, spaceFrom != nil {
                movedBefore = moved
                spaceFrom = nil
                heldOut = nil
            }
        }

        /// The out tangent the drag gives, from the point at `point`.
        func outTangent(from point: CGPoint) -> CGVector {
            guard dragged else { return .zero }
            if let heldOut { return PenTool.tenths(heldOut) }
            var tangent = pointer - point
            if shift { tangent = PenTool.snapped45(tangent) }
            return PenTool.tenths(tangent)
        }

        /// The in tangent that goes with `out`: its mirror, or the one kept
        /// since Option went down.
        func inTangent(mirroring out: CGVector) -> CGVector {
            keptIn ?? (dragged ? -out : .zero)
        }
    }

    /// What a press made: the project after it, the pen's state and the
    /// point it picked, the undo step's name, and what to select.
    struct Outcome {
        var project: EditingProject
        var state: PenState
        var picked: Int?
        var name: String
        /// A new effect, selected in the timeline and the effects panel.
        var made: (layerID: UUID, clipID: UUID, effectID: UUID)?
    }

    /// Why a press is refused.
    enum Refusal: Error, Equatable, Sendable {
        /// Mask, with no clip selected that can take one.
        case nothingToMask
        case locked
        case driven(HandleRefusal)

        var message: String? {
            switch self {
            case .nothingToMask: "Select a clip to mask."
            case .locked, .driven: nil
            }
        }
    }

    /// A press ready to run: the project it starts from (with a new path's
    /// empty effect already in it), the path, and what the press does.
    struct Begun {
        var project: EditingProject
        var state: PenState
        var target: PenTarget
        var located: PathHandles.Located
        var action: Action
        /// A new effect made for the press.
        var made: (layerID: UUID, clipID: UUID, effectID: UUID)?
        /// Whether the press started the path.
        var starts: Bool
    }

    /// Readies a press with `action` on `current` (the path the pen works
    /// on, if any): a press that places a point with no path being drawn
    /// starts one where docs/pen-tool.md, "What a new path becomes", says.
    static func begin(
        _ action: Action, on current: PenTarget?, state: PenState, in project: EditingProject, _ setting: Setting
    ) -> Result<Begun, Refusal> {
        var state = state
        var project = project
        var made: (layerID: UUID, clipID: UUID, effectID: UUID)?
        var target: PenTarget
        var starts = false
        if action == .place, !isDrawing(state, in: project, setting) {
            switch start(state.mode, in: &project, setting) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let started):
                target = started.target
                made = started.made
                if !started.isNew {
                    // An effect waiting for its path keeps it: Escape takes
                    // the points.
                    state.added = .points(from: 0)
                } else {
                    state.added = .effect(layerID: started.existingLayer == nil ? started.made?.layerID : nil)
                }
                starts = true
            }
            state.target = target
            state.ended = false
        } else {
            guard let current else { return .failure(.nothingToMask) }
            target = current
        }
        if setting.locked.contains(target.clipID) { return .failure(.locked) }
        guard let located = locate(target, in: project, setting) else { return .failure(.nothingToMask) }
        if let clip = project.clipAndLayer(target.clipID, in: setting.timelineID)?.clip,
           let driven = PathHandles.driver(of: located, in: clip) {
            return .failure(.driven(driven))
        }
        return .success(Begun(project: project, state: state, target: target, located: located, action: action, made: made, starts: starts))
    }

    private struct Started {
        var target: PenTarget
        var made: (layerID: UUID, clipID: UUID, effectID: UUID)?
        /// The layer it went on, when it already was there.
        var existingLayer: UUID?
        /// Whether the effect is new, rather than one waiting for a path.
        var isNew: Bool
    }

    /// Where a new path goes: into the Path or Path Mask picked in the
    /// effects panel while it has no path yet; else for Shape a new Path,
    /// in the selected clip if it is a shape clip under the playhead (below
    /// the shapes it has) or on a new shape layer at the top holding a
    /// five-second clip at the playhead; for Mask a new Path Mask at the
    /// end of the selected clip's stack, above trailing Blending effects.
    private static func start(_ mode: PenState.Mode, in project: inout EditingProject, _ setting: Setting) -> Result<Started, Refusal> {
        let selected = setting.selection.flatMap { selection -> (clip: TimelineClip, layer: TimelineLayer)? in
            guard selection.timelineID == setting.timelineID,
                  let found = project.clipAndLayer(selection.timelineClipID, in: setting.timelineID),
                  found.clip.enabled, setting.time >= found.clip.startOffset, setting.time < found.clip.endOffset
            else { return nil }
            return found
        }
        if let selected, let effectID = setting.selectedEffectID, let effect = selected.clip.effect(id: effectID),
           PathHandles.applies(to: effect), effect.control(.path).map({ $0.number.value.values.isEmpty && !$0.number.isAnimated }) ?? false {
            return .success(Started(target: PenTarget(clipID: selected.clip.id, effectID: effectID), made: nil, existingLayer: selected.layer.id, isNew: false))
        }
        switch mode {
        case .shape:
            if let selected, selected.clip.source == .graphic, !setting.locked.contains(selected.clip.id) {
                let at = (selected.clip.effects.lastIndex { $0.kind.drawsShape }).map { $0 + 1 } ?? 0
                guard let effectID = project.addEffect(.path, toClip: selected.clip.id, in: setting.timelineID, at: at) else { break }
                return .success(Started(
                    target: PenTarget(clipID: selected.clip.id, effectID: effectID),
                    made: (selected.layer.id, selected.clip.id, effectID), existingLayer: selected.layer.id, isNew: true
                ))
            }
            guard let timeline = project.timeline(id: setting.timelineID) else { return .failure(.nothingToMask) }
            let from = timeline.frameAligned(setting.time, .down)
            guard let added = project.addShapeLayer(.path, to: setting.timelineID, at: 0, from: from),
                  let effectID = project.clipAndLayer(added.clipID, in: setting.timelineID)?.clip.effects.first?.id
            else { return .failure(.nothingToMask) }
            return .success(Started(
                target: PenTarget(clipID: added.clipID, effectID: effectID), made: (added.layerID, added.clipID, effectID),
                existingLayer: nil, isNew: true
            ))
        case .mask:
            break
        }
        guard mode == .mask, let selected, project.hasEffectStack(selected.clip), !setting.locked.contains(selected.clip.id) else {
            return .failure(.nothingToMask)
        }
        let effects = selected.clip.effects
        var at = effects.count
        while at > 0, effects[at - 1].kind == .blending { at -= 1 }
        guard let effectID = project.addEffect(.pathMask, toClip: selected.clip.id, in: setting.timelineID, at: at) else {
            return .failure(.nothingToMask)
        }
        return .success(Started(
            target: PenTarget(clipID: selected.clip.id, effectID: effectID), made: (selected.layer.id, selected.clip.id, effectID),
            existingLayer: selected.layer.id, isNew: true
        ))
    }

    /// The project after the press so far, worked out from `begun`'s; nil
    /// when it changes nothing. With `picked`, the point it leaves picked.
    static func step(_ begun: Begun, _ stroke: Stroke, _ setting: Setting) -> Outcome? {
        let located = begun.located
        var path = located.path
        var control = located.control
        var picked: Int?
        var name: String
        let time = located.sourceTime
        var state = begun.state
        switch stroke.action {
        case .place:
            var point = wholePixels(stroke.start)
            if stroke.shiftAtPress, let last = path.vertices.last {
                point = wholePixels(last.point + snapped45(point - last.point))
            }
            point = CGPoint(x: point.x + stroke.moved.dx.rounded(), y: point.y + stroke.moved.dy.rounded())
            let out = stroke.outTangent(from: point)
            let vertex = FreePath.Vertex(point, in: stroke.inTangent(mirroring: out), out: out)
            // Every keyframe gets the point, so they keep one count.
            control.mapPath { $0.vertices.append(vertex) }
            path.vertices.append(vertex)
            picked = path.vertices.count - 1
            name = begun.starts ? "Draw Path" : "Add Point"
        case .close:
            guard path.vertices.count >= 2 else { return nil }
            path.closed = true
            if stroke.dragged {
                let drag = tenths(snappedIf(stroke.shift, stroke.pointer - path.vertices[0].point))
                path.vertices[0].inTangent = -drag
                if !stroke.option { path.vertices[0].outTangent = drag }
            }
            control.setPath(path, at: time)
            picked = 0
            name = "Close Path"
        case .retract:
            guard let last = path.vertices.indices.last else { return nil }
            path.vertices[last].outTangent = stroke.dragged ? stroke.outTangent(from: path.vertices[last].point) : .zero
            control.setPath(path, at: time)
            picked = last
            name = "Convert Point"
        case .carryOn(let end):
            state.target = begun.target
            state.ended = false
            if end == 0, path.vertices.count > 1 {
                control.mapPath { $0 = reversed($0) }
                path = reversed(path)
            }
            let last = path.vertices.count - 1
            if stroke.dragged {
                path.vertices[last].outTangent = stroke.outTangent(from: path.vertices[last].point)
                control.setPath(path, at: time)
            }
            state.added = .points(from: path.vertices.count)
            picked = last
            name = "Carry On Path"
        case .remove(let index):
            control.mapPath { $0.remove(index) }
            path.remove(index)
            picked = path.vertices.isEmpty ? nil : min(index, path.vertices.count - 1)
            if case .points(let from)? = state.added, index < from { state.added = .points(from: from - 1) }
            name = "Remove Point"
        case .insert(let segment, let t):
            var at: Int?
            control.mapPath { at = $0.split(segment: segment, at: t) ?? at }
            picked = at
            name = "Add Point"
        case .convert(let index):
            guard path.vertices.indices.contains(index) else { return nil }
            if stroke.dragged {
                let out = stroke.outTangent(from: path.vertices[index].point)
                path.vertices[index].outTangent = out
                path.vertices[index].inTangent = -out
            } else {
                // Only an ease (or broken) point changes: a linear one has
                // nothing to take away.
                path.vertices[index].inTangent = .zero
                path.vertices[index].outTangent = .zero
            }
            control.setPath(path, at: time)
            picked = index
            name = "Convert Point"
        case .moveTangent(let index, let side):
            guard stroke.dragged, path.vertices.indices.contains(index) else { return nil }
            let tangent = tenths(snappedIf(stroke.shift, stroke.pointer - path.vertices[index].point))
            path = PathHandles.moving(tangent: side, of: index, in: path, to: tangent, keepsPair: false)
            control.setPath(path, at: time)
            picked = index
            name = "Convert Point"
        case .bend(let segment, let t):
            guard stroke.dragged else { return nil }
            path.bend(segment: segment, at: t, through: stroke.pointer)
            let index = segment, next = path.segmentEnd(segment)
            path.vertices[index].outTangent = tenths(path.vertices[index].outTangent)
            path.vertices[next].inTangent = tenths(path.vertices[next].inTangent)
            control.setPath(path, at: time)
            picked = nil
            name = "Bend Path"
        }
        var project = begun.project
        let target = begun.target
        project.editEffect(target.effectID, ofClip: target.clipID, in: setting.timelineID) { effect in
            if let index = effect.controls.firstIndex(where: { $0.id == control.id }) { effect.controls[index] = control }
        }
        var carriesOn = false
        if case .carryOn = stroke.action { carriesOn = true }
        if project == begun.project, !begun.starts, !carriesOn { return nil }
        return Outcome(project: project, state: state, picked: picked, name: name, made: begun.made)
    }

    /// `path` the other way round: its points in reverse, each with its
    /// tangents swapped.
    static func reversed(_ path: FreePath) -> FreePath {
        FreePath(
            vertices: path.vertices.reversed().map { FreePath.Vertex($0.point, in: $0.outTangent, out: $0.inTangent) },
            closed: path.closed
        )
    }

    // MARK: Ending a draw

    /// Return: ends the draw open. A mask is closed with a straight
    /// stretch, since an open mask cuts nothing; a shape that would draw
    /// nothing open (it has no stroke) gets its Stroke turned on, in its
    /// fill's color, 4 pixels wide. A draw of fewer than two points is
    /// taken away, as Escape would. Nil while nothing is being drawn.
    static func end(_ state: PenState, in project: EditingProject, _ setting: Setting) -> Outcome? {
        guard isDrawing(state, in: project, setting), let target = state.target, let located = locate(target, in: project, setting) else {
            return nil
        }
        if located.path.vertices.count < 2 { return cancel(state, in: project, setting) }
        var project = project
        var state = state
        var name = "End Path"
        project.editEffect(target.effectID, ofClip: target.clipID, in: setting.timelineID) { effect in
            if effect.kind == .pathMask {
                effect.changeControl(.path) { $0.closed = true }
                name = "Close Path"
            } else if ShapeStroke(effect, at: located.sourceTime) == nil {
                let fill = effect.control(.fill).map { $0.values(at: located.sourceTime) } ?? [1, 1, 1, 1]
                effect.changeControl(.stroke) { control in
                    control.enabled = true
                    if control.values(at: located.sourceTime).last ?? 0 <= 0 || control.isAtDefault {
                        control.number = AnimatedValue(ComponentValue(values: fill.count == 4 ? fill : [1, 1, 1, 1]))
                    }
                }
                effect.changeControl(.strokeWidth) { control in
                    control.enabled = true
                    if (control.values(at: located.sourceTime).first ?? 0) <= 0 { control.number = AnimatedValue(ComponentValue(values: [4])) }
                }
            }
        }
        state.ended = true
        state.added = nil
        return Outcome(project: project, state: state, picked: nil, name: name, made: nil)
    }

    /// Escape while a path is being drawn: what the draw added goes, the
    /// effect it made (with its clip and layer) or the points it added to
    /// a path already there. Nil while nothing is being drawn.
    static func cancel(_ state: PenState, in project: EditingProject, _ setting: Setting) -> Outcome? {
        guard isDrawing(state, in: project, setting), let target = state.target else { return nil }
        var project = project
        var state = state
        switch state.added {
        case .effect(let layerID)?:
            if let layerID {
                project.updateTimeline(setting.timelineID) { $0.layers.removeAll { $0.id == layerID } }
            } else {
                project.removeEffect(target.effectID, fromClip: target.clipID, in: setting.timelineID)
            }
            state.target = nil
        case .points(let from)?:
            project.editEffect(target.effectID, ofClip: target.clipID, in: setting.timelineID) { effect in
                effect.changeControl(.path) { control in
                    control.mapPath { path in
                        if path.vertices.count > from { path.vertices.removeSubrange(from...) }
                    }
                }
            }
            state.ended = true
        case nil:
            state.ended = true
        }
        state.added = nil
        return Outcome(project: project, state: state, picked: nil, name: "Cancel Path", made: nil)
    }

    // MARK: Rounding

    static func wholePixels(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.rounded(), y: point.y.rounded())
    }

    static func tenths(_ vector: CGVector) -> CGVector {
        CGVector(dx: (vector.dx * 10).rounded() / 10, dy: (vector.dy * 10).rounded() / 10)
    }

    /// `vector` turned to the nearest multiple of 45°, its length along it
    /// kept.
    static func snapped45(_ vector: CGVector) -> CGVector {
        let length = vector.length
        guard length > 0 else { return vector }
        let step = Double.pi / 4
        let angle = (atan2(Double(vector.dy), Double(vector.dx)) / step).rounded() * step
        return CGVector(dx: length * cos(angle), dy: length * sin(angle))
    }

    private static func snappedIf(_ shift: Bool, _ vector: CGVector) -> CGVector {
        shift ? snapped45(vector) : vector
    }
}

private extension CGVector {
    static func + (a: CGVector, b: CGVector) -> CGVector { CGVector(dx: a.dx + b.dx, dy: a.dy + b.dy) }
}
