import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// What the viewer's canvases keep besides the project (see
/// docs/viewer-handles.md, "State"): the tool, what the arrow keys change,
/// and the drag in progress, which the handles are drawn from while the
/// project holds the drag to one side. The editor owns it and hands it to
/// its surface's viewer and to the synced external display, so a drag on
/// one display is drawn on both.
@MainActor
@Observable
final class ViewerCanvasState {
    var tool = ViewerTool.arrow
    /// What the pen keeps between presses: Shape or Mask, the path it
    /// works on, and what its draw added (see docs/pen-tool.md).
    var pen = PenState()
    /// A press of the pen is under way, which a pinch or a scroll leaves
    /// alone, as it does a handle's drag.
    var isPenPressed = false
    /// A drawn path's clip, selected in the timeline: the one place the
    /// viewer changes the selection, to what it has just made. Set by the
    /// surface that owns the selection while it is shown.
    var select: ((TimelineSelection) -> Void)?
    /// What the arrows change while the canvas has the keys (Tab): one of
    /// the handle sets' `keyTargets`, by its handle; the first when this
    /// isn't among them.
    var picked: HandleID = .move
    /// A path's points picked together (⌘-click with the arrow, ⌘A with
    /// the pen), which a drag of one of them and the arrows move as one.
    /// `picked` names the one whose tangents show.
    var pointSelection: PathPointSelection?
    var drag: Drag?
    /// The editor surface's parked playhead and effects panel, which a
    /// canvas outside the surface (the external display's) shows the
    /// handles at and picks the Transform by. Set by the surface while it
    /// is shown.
    private(set) var playhead: PlayheadState?
    private(set) var effects: EffectsPanelState?

    /// The surface showing `playhead` and `effects` is the one other
    /// canvases follow; `select` selects a clip in its timeline.
    func follow(playhead: PlayheadState, effects: EffectsPanelState, select: ((TimelineSelection) -> Void)? = nil) {
        if self.playhead !== playhead { self.playhead = playhead }
        if self.effects !== effects { self.effects = effects }
        if let select { self.select = select }
    }

    /// Picks the pen to draw or edit the path of `effectID` (a Path or a
    /// Path Mask) on `clipID`: a draw under way on another path ends, so
    /// the pen works on this one, the one selected in the effects panel.
    func drawWithPen(_ effectID: UUID, kind: EffectKind, onClip clipID: UUID) {
        pick(.pen, mode: kind == .pathMask ? .mask : .shape)
        if pen.target?.effectID != effectID {
            pen.target = PenTarget(clipID: clipID, effectID: effectID)
            pen.ended = true
            pen.added = nil
        }
    }

    /// The points picked together on the path of `effectID`, while it still
    /// has `count` points; none otherwise, since the indices would name
    /// other points.
    func pickedPoints(of effectID: UUID, count: Int) -> Set<Int> {
        guard let selection = pointSelection, selection.effectID == effectID, selection.count == count else { return [] }
        return selection.points
    }

    /// Picks `points` of the path of `effectID`, which has `count`; one
    /// point or none clears the selection, `picked` saying the one.
    func pickPoints(_ points: Set<Int>, of effectID: UUID, count: Int) {
        let next = points.count > 1 ? PathPointSelection(effectID: effectID, count: count, points: points) : nil
        if pointSelection != next { pointSelection = next }
    }

    /// Picks `tool`; the pen set to `mode` when given.
    func pick(_ tool: ViewerTool, mode: PenState.Mode? = nil) {
        if self.tool != tool { self.tool = tool }
        if let mode, pen.mode != mode { pen.mode = mode }
    }

    /// That surface is gone.
    func stopFollowing(_ playhead: PlayheadState) {
        guard self.playhead === playhead else { return }
        self.playhead = nil
        effects = nil
        select = nil
    }

    /// A drag on a handle so far.
    struct Drag {
        var handle: HandleID
        var clipID: UUID
        /// The clip as the drag has made it, which the handles are drawn
        /// from: the project shows the clip from before the drag until it
        /// ends.
        var clip: TimelineClip
        /// The value reached, as the readout says it.
        var readout: String
        /// Where the pointer is, in view points.
        var pointer: CGPoint
        /// The loupe, while a held press has opened it.
        var loupe: Loupe?
    }

    /// What the loupe shows (see `FineDrag`).
    struct Loupe: Equatable {
        /// The spot the drag has reached, in the frame's pixels, which the
        /// loupe is centered on.
        var center: CGPoint
        /// Whether Option slows it further.
        var isFiner: Bool
    }
}

/// What the viewer's handles are drawn from and edit, given by the editor's
/// surface. Absent in viewers that edit nothing.
struct ViewerHandlesSource {
    var project: Binding<EditingProject>
    var timelineID: UUID
    var selection: TimelineSelection?
    var effectsState: EffectsPanelState
    var playhead: PlayheadState
    var state: ViewerCanvasState
}

/// Points of one path picked together (`ViewerCanvasState.pointSelection`).
struct PathPointSelection: Equatable {
    var effectID: UUID
    /// How many points the path had: a point added or removed shifts the
    /// indices, which then pick nothing.
    var count: Int
    var points: Set<Int>
}
