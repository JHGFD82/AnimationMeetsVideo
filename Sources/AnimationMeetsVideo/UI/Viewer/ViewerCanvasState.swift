import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// What the viewer's canvas keeps besides the project (see
/// docs/viewer-handles.md, "State"): the tool, what the arrow keys change,
/// and the drag in progress, which the handles are drawn from while the
/// project holds the drag to one side. The editor's surface owns it.
@MainActor
@Observable
final class ViewerCanvasState {
    var tool = ViewerTool.arrow
    /// What the arrows change while the canvas has the keys (Tab).
    var part = TransformHandles.Part.position
    var drag: Drag?

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
