import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The pen as plain logic (docs/pen-tool.md, "Drawing"): presses run as
/// the canvas runs them, each worked out from the project before it.
@Suite struct PenToolTests {
    /// A project, the pen's state, and what is selected, pressed on as the
    /// canvas presses: points in the path's own coordinates.
    private struct Rig {
        var project = EditingProject.empty
        var state = PenState()
        var selection: TimelineSelection?
        var selectedEffectID: UUID?
        var time = CMTime(value: 1, timescale: 1)

        var timelineID: UUID { project.rootTimelineID }

        var setting: PenTool.Setting {
            PenTool.Setting(timelineID: timelineID, time: time, selection: selection, selectedEffectID: selectedEffectID)
        }

        var current: (target: PenTarget, located: PathHandles.Located)? { PenTool.current(state, in: project, setting) }

        var path: FreePath? { current?.located.path }

        var drawing: Bool { PenTool.isDrawing(state, in: project, setting) }

        /// A press with `action` at `at`, dragged to `to` if given, as one
        /// step; `during` changes the stroke after the drag, before the
        /// last step (Option or Space going down).
        @discardableResult
        mutating func press(
            _ action: PenTool.Action = .place, at: CGPoint, to: CGPoint? = nil, shift: Bool = false, option: Bool = false,
            then more: [(inout PenTool.Stroke) -> Void] = []
        ) throws -> PenTool.Outcome? {
            let begun = try PenTool.begin(action, on: current?.target, state: state, in: project, setting).get()
            var stroke = PenTool.Stroke(action: action, at: at, shift: shift, option: option)
            if let to {
                stroke.dragged = true
                stroke.move(to: to)
            }
            for change in more { change(&stroke) }
            let outcome = PenTool.step(begun, stroke, setting)
            if let outcome { apply(outcome) }
            return outcome
        }

        /// A press that lands where the pen finds it: what it hits decides
        /// the action, as the canvas does with no zoom.
        @discardableResult
        mutating func click(_ at: CGPoint, to: CGPoint? = nil, option: Bool = false) throws -> PenTool.Outcome? {
            let shown = current
            let toView: (CGPoint) -> CGPoint = { point in
                guard let shown else { return point }
                return shown.located.toPath(point) ?? point
            }
            let hit = PenTool.hit(at, on: shown?.located, picked: nil, tangents: option, toView: toView)
            let action = PenTool.action(for: hit, path: shown?.located.path, drawing: drawing, option: option)
            return try press(action, at: at, to: to, option: option)
        }

        mutating func apply(_ outcome: PenTool.Outcome) {
            project = outcome.project
            state = outcome.state
            if let made = outcome.made {
                selection = TimelineSelection(timelineID: timelineID, layerID: made.layerID, timelineClipID: made.clipID)
                selectedEffectID = made.effectID
            }
        }

        var layerCount: Int { project.timeline(id: timelineID)?.layers.count ?? 0 }
    }

    // MARK: Placing

    @Test func aClickPlacesALinearPointAndADragAnEaseOne() throws {
        var rig = Rig()
        let first = try req(try rig.press(at: CGPoint(x: 10.4, y: 20.6)))
        #expect(first.name == "Draw Path")
        #expect(rig.path?.vertices == [FreePath.Vertex(CGPoint(x: 10, y: 21))])
        #expect(rig.drawing)
        let second = try req(try rig.press(at: CGPoint(x: 100, y: 0), to: CGPoint(x: 130, y: 40)))
        #expect(second.name == "Add Point")
        let vertex = try req(rig.path?.vertices.last)
        #expect(vertex.outTangent == CGVector(dx: 30, dy: 40))
        #expect(vertex.inTangent == CGVector(dx: -30, dy: -40))
        #expect(rig.path?.kind(of: 1) == .ease)
        #expect(second.picked == 1)
    }

    @Test func shiftKeepsAPointAndATangentOnMultiplesOf45Degrees() throws {
        var rig = Rig()
        try rig.press(at: .zero)
        try rig.press(at: CGPoint(x: 100, y: 8), shift: true)
        #expect(rig.path?.vertices[1].point == CGPoint(x: 100, y: 0))
        try rig.press(at: CGPoint(x: 200, y: 0), to: CGPoint(x: 240, y: 37), then: [{ $0.shift = true }])
        let out = try req(rig.path?.vertices[2].outTangent)
        #expect(abs(out.dx - out.dy) < 0.11)
    }

    @Test func optionMidDragBreaksThePair() throws {
        var rig = Rig()
        try rig.press(at: .zero)
        try rig.press(at: CGPoint(x: 100, y: 0), to: CGPoint(x: 130, y: 0), then: [
            { $0.setOption(true) },
            { $0.move(to: CGPoint(x: 100, y: 50)) },
        ])
        let vertex = try req(rig.path?.vertices[1])
        // The in tangent stays where it was as Option went down.
        #expect(vertex.inTangent == CGVector(dx: -30, dy: 0))
        #expect(vertex.outTangent == CGVector(dx: 0, dy: 50))
        #expect(rig.path?.kind(of: 1) == .broken)
    }

    @Test func spaceMidDragMovesThePointTangentsAndAll() throws {
        var rig = Rig()
        try rig.press(at: .zero)
        try rig.press(at: CGPoint(x: 100, y: 0), to: CGPoint(x: 120, y: 0), then: [
            { $0.setSpace(true) },
            { $0.move(to: CGPoint(x: 120, y: 30)) },
            { $0.setSpace(false) },
        ])
        let vertex = try req(rig.path?.vertices[1])
        #expect(vertex.point == CGPoint(x: 100, y: 30))
        #expect(vertex.outTangent == CGVector(dx: 20, dy: 0))
    }

    // MARK: Closing and ending

    @Test func clickingTheFirstPointClosesTheDraw() throws {
        var rig = Rig()
        try rig.click(.zero)
        try rig.click(CGPoint(x: 100, y: 0))
        try rig.click(CGPoint(x: 100, y: 100))
        let closed = try req(try rig.click(CGPoint(x: 1, y: 1)))
        #expect(closed.name == "Close Path")
        #expect(rig.path?.closed == true)
        #expect(rig.path?.vertices.count == 3)
        #expect(!rig.drawing)
    }

    @Test func draggingAsItClosesShapesTheClosingCurve() throws {
        var rig = Rig()
        try rig.click(.zero)
        try rig.click(CGPoint(x: 100, y: 0))
        try rig.click(CGPoint(x: 100, y: 100))
        try rig.click(.zero, to: CGPoint(x: 0, y: -20))
        let first = try req(rig.path?.vertices.first)
        #expect(first.inTangent == CGVector(dx: 0, dy: 20))
        #expect(first.outTangent == CGVector(dx: 0, dy: -20))
    }

    @Test func clickingTheLastPointTakesItsOutTangentAway() throws {
        var rig = Rig()
        try rig.click(.zero)
        try rig.click(CGPoint(x: 100, y: 0), to: CGPoint(x: 140, y: 0))
        let retracted = try req(try rig.click(CGPoint(x: 100, y: 0)))
        #expect(retracted.name == "Convert Point")
        #expect(rig.path?.vertices[1].outTangent == .zero)
        #expect(rig.path?.vertices[1].inTangent == CGVector(dx: -40, dy: 0))
        #expect(rig.drawing)
    }

    @Test func returnLeavesAShapeOpenAndStrokedAndClosesAMask() throws {
        var shape = Rig()
        try shape.click(.zero)
        try shape.click(CGPoint(x: 100, y: 0))
        let ended = try req(PenTool.end(shape.state, in: shape.project, shape.setting))
        shape.apply(ended)
        #expect(shape.path?.closed == false)
        #expect(!shape.drawing)
        let effect = try req(shape.current?.located.effect)
        #expect(ShapeStroke(effect, at: .zero) != nil)

        var mask = Rig()
        let clip = try req(mask.project.addShapeLayer(.rectangle, to: mask.timelineID))
        mask.selection = TimelineSelection(timelineID: mask.timelineID, layerID: clip.layerID, timelineClipID: clip.clipID)
        mask.state.mode = .mask
        try mask.click(.zero)
        try mask.click(CGPoint(x: 100, y: 0))
        try mask.click(CGPoint(x: 100, y: 100))
        let closed = try req(PenTool.end(mask.state, in: mask.project, mask.setting))
        #expect(closed.name == "Close Path")
        mask.apply(closed)
        #expect(mask.path?.closed == true)
    }

    @Test func aDrawOfOnePointEndedIsTakenAway() throws {
        var rig = Rig()
        try rig.click(.zero)
        #expect(rig.layerCount == 1)
        let ended = try req(PenTool.end(rig.state, in: rig.project, rig.setting))
        #expect(ended.name == "Cancel Path")
        rig.apply(ended)
        #expect(rig.layerCount == 0)
    }

    // MARK: Editing

    @Test func addingAndRemovingPointsActsOnEveryKeyframe() throws {
        var rig = Rig()
        try rig.click(.zero)
        try rig.click(CGPoint(x: 100, y: 0))
        try rig.click(CGPoint(x: 100, y: 100))
        try rig.click(.zero)
        // Animate the path: a second keyframe with the square bigger.
        let target = try req(rig.current?.target)
        let source = try req(rig.current?.located.sourceTime)
        rig.project.editEffect(target.effectID, ofClip: target.clipID, in: rig.timelineID) { effect in
            effect.changeControl(.path) { control in
                control.number.setAnimated(true, at: .zero)
                var later = control.freePath(at: .zero)
                for index in later.vertices.indices { later.vertices[index].point.x *= 2 }
                control.setPath(later, at: CMTimeAdd(source, CMTime(value: 1, timescale: 1)))
            }
        }
        func counts() -> [Int] {
            let control = rig.project.clipAndLayer(target.clipID, in: rig.timelineID)?.clip.effect(id: target.effectID)?.control(.path)
            return control?.number.keyframes.map { $0.value.values.count / FreePath.numbersPerVertex } ?? []
        }
        #expect(counts() == [3, 3])
        let added = try req(try rig.click(CGPoint(x: 50, y: 0)))
        #expect(added.name == "Add Point")
        #expect(counts() == [4, 4])
        let removed = try req(try rig.click(CGPoint(x: 100, y: 100)))
        #expect(removed.name == "Remove Point")
        #expect(counts() == [3, 3])
    }

    @Test func drawingCarriesOnFromEitherEnd() throws {
        var rig = Rig()
        try rig.click(.zero)
        try rig.click(CGPoint(x: 100, y: 0))
        rig.apply(try req(PenTool.end(rig.state, in: rig.project, rig.setting)))
        #expect(!rig.drawing)
        // From the last end: drawn on as it was.
        let carried = try req(try rig.click(CGPoint(x: 100, y: 0)))
        #expect(carried.name == "Carry On Path")
        #expect(rig.drawing)
        try rig.click(CGPoint(x: 200, y: 0))
        #expect(rig.path?.vertices.map(\.point) == [.zero, CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 0)])
        rig.apply(try req(PenTool.end(rig.state, in: rig.project, rig.setting)))
        // From the first: turned round, so it is the end drawn on.
        try rig.click(.zero)
        try rig.click(CGPoint(x: -100, y: 0))
        #expect(rig.path?.vertices.map(\.point) == [CGPoint(x: 200, y: 0), CGPoint(x: 100, y: 0), .zero, CGPoint(x: -100, y: 0)])
    }

    @Test func optionConverts() throws {
        var rig = Rig()
        try rig.click(.zero)
        try rig.click(CGPoint(x: 100, y: 0), to: CGPoint(x: 130, y: 0))
        try rig.click(CGPoint(x: 200, y: 0))
        // Option-click an ease point: linear.
        try rig.click(CGPoint(x: 100, y: 0), option: true)
        #expect(rig.path?.kind(of: 1) == .linear)
        // Option-click a linear one: nothing.
        #expect(try rig.click(CGPoint(x: 100, y: 0), option: true) == nil)
        // Option-drag from a point: fresh mirrored tangents.
        try rig.click(CGPoint(x: 100, y: 0), to: CGPoint(x: 100, y: 25), option: true)
        #expect(rig.path?.vertices[1].outTangent == CGVector(dx: 0, dy: 25))
        #expect(rig.path?.kind(of: 1) == .ease)
        // Option-drag a tangent's end: it alone, breaking the pair.
        try rig.press(.moveTangent(1, .out), at: CGPoint(x: 100, y: 25), to: CGPoint(x: 140, y: 0))
        #expect(rig.path?.vertices[1].outTangent == CGVector(dx: 40, dy: 0))
        #expect(rig.path?.vertices[1].inTangent == CGVector(dx: 0, dy: -25))
        // Option-drag a stretch: it bends through the pointer.
        try rig.press(.bend(segment: 1, t: 0.5), at: CGPoint(x: 150, y: 0), to: CGPoint(x: 150, y: 40))
        let reached = try req(rig.path?.point(onSegment: 1, at: 0.5))
        #expect(abs(reached.y - 40) < 0.2)
    }

    // MARK: What a new path becomes

    @Test func aNewPathGoesWhereTheRulesSay() throws {
        // A Path Mask with no path, picked in the panel: its path.
        var waiting = Rig()
        let clip = try req(waiting.project.addShapeLayer(.rectangle, to: waiting.timelineID))
        let maskID = try req(waiting.project.addEffect(.pathMask, toClip: clip.clipID, in: waiting.timelineID))
        waiting.selection = TimelineSelection(timelineID: waiting.timelineID, layerID: clip.layerID, timelineClipID: clip.clipID)
        waiting.selectedEffectID = maskID
        let first = try req(try waiting.click(.zero))
        #expect(first.made == nil)
        #expect(waiting.current?.target.effectID == maskID)

        // Shape, with a shape clip selected: a Path below its shapes.
        var inClip = Rig()
        let shapes = try req(inClip.project.addShapeLayer(.rectangle, to: inClip.timelineID))
        inClip.project.editClip(shapes.clipID, in: inClip.timelineID) { $0.effects.append(Effect(kind: .transform)) }
        inClip.selection = TimelineSelection(timelineID: inClip.timelineID, layerID: shapes.layerID, timelineClipID: shapes.clipID)
        try inClip.click(.zero)
        let kinds = inClip.project.clipAndLayer(shapes.clipID, in: inClip.timelineID)?.clip.effects.map(\.kind)
        #expect(kinds == [.rectangle, .path, .transform])
        #expect(inClip.layerCount == 1)

        // Shape, with nothing selected: a new shape layer at the top.
        var alone = Rig()
        let made = try req(try alone.click(.zero)?.made)
        #expect(alone.layerCount == 1)
        #expect(alone.project.timeline(id: alone.timelineID)?.layers.first?.id == made.layerID)

        // Mask: at the end of the stack, above trailing Blending.
        var masked = Rig()
        let base = try req(masked.project.addShapeLayer(.rectangle, to: masked.timelineID))
        masked.project.editClip(base.clipID, in: masked.timelineID) { $0.effects.append(Effect(kind: .blending)) }
        masked.selection = TimelineSelection(timelineID: masked.timelineID, layerID: base.layerID, timelineClipID: base.clipID)
        masked.state.mode = .mask
        try masked.click(.zero)
        let stack = masked.project.clipAndLayer(base.clipID, in: masked.timelineID)?.clip.effects.map(\.kind)
        #expect(stack == [.rectangle, .pathMask, .blending])

        // Mask with nothing selected: refused.
        var nothing = Rig()
        nothing.state.mode = .mask
        #expect(throws: PenTool.Refusal.nothingToMask) { try nothing.click(.zero) }
    }

    // MARK: Escape

    @Test func escapeTakesAwayWhatTheDrawAdded() throws {
        // A new layer goes with its effect.
        var layer = Rig()
        try layer.click(.zero)
        try layer.click(CGPoint(x: 10, y: 0))
        layer.apply(try req(PenTool.cancel(layer.state, in: layer.project, layer.setting)))
        #expect(layer.layerCount == 0)

        // An effect made in a clip that was there: the effect alone.
        var effect = Rig()
        let shapes = try req(effect.project.addShapeLayer(.rectangle, to: effect.timelineID))
        effect.selection = TimelineSelection(timelineID: effect.timelineID, layerID: shapes.layerID, timelineClipID: shapes.clipID)
        try effect.click(.zero)
        let cancelled = try req(PenTool.cancel(effect.state, in: effect.project, effect.setting))
        #expect(cancelled.name == "Cancel Path")
        effect.apply(cancelled)
        #expect(effect.project.clipAndLayer(shapes.clipID, in: effect.timelineID)?.clip.effects.map(\.kind) == [.rectangle])

        // Points added to a path that was there: the points alone.
        var points = Rig()
        try points.click(.zero)
        try points.click(CGPoint(x: 100, y: 0))
        points.apply(try req(PenTool.end(points.state, in: points.project, points.setting)))
        try points.click(CGPoint(x: 100, y: 0))
        try points.click(CGPoint(x: 200, y: 0))
        try points.click(CGPoint(x: 300, y: 0))
        points.apply(try req(PenTool.cancel(points.state, in: points.project, points.setting)))
        #expect(points.path?.vertices.count == 2)
        #expect(points.layerCount == 1)

        // Nothing drawn: nothing to cancel.
        #expect(PenTool.cancel(points.state, in: points.project, points.setting) == nil)
    }
}

/// `#require` for a value worked out first, which may come from a
/// mutating call (the macro can't wrap one).
private func req<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}

extension PenTool.Outcome: Equatable {
    public static func == (lhs: PenTool.Outcome, rhs: PenTool.Outcome) -> Bool {
        lhs.project == rhs.project && lhs.state == rhs.state && lhs.name == rhs.name
    }
}
