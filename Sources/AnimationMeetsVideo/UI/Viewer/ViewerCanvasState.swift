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
    /// What the arrows change while the canvas has the keys (Tab): one of
    /// the handle sets' `keyTargets`, by its handle; the first when this
    /// isn't among them.
    var picked: HandleID = .move
    var drag: Drag?
    /// The editor surface's parked playhead and effects panel, which a
    /// canvas outside the surface (the external display's) shows the
    /// handles at and picks the Transform by. Set by the surface while it
    /// is shown.
    private(set) var playhead: PlayheadState?
    private(set) var effects: EffectsPanelState?

    /// The surface showing `playhead` and `effects` is the one other
    /// canvases follow.
    func follow(playhead: PlayheadState, effects: EffectsPanelState) {
        if self.playhead !== playhead { self.playhead = playhead }
        if self.effects !== effects { self.effects = effects }
    }

    /// That surface is gone.
    func stopFollowing(_ playhead: PlayheadState) {
        guard self.playhead === playhead else { return }
        self.playhead = nil
        effects = nil
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
