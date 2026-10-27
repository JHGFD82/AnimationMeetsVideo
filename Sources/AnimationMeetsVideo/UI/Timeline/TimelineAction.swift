import CoreMedia
import Foundation

/// What the timeline asks its owner to do (`TimelineHost.dispatch`): the
/// edits it makes to the project, and what it changes beyond itself (the
/// selection, the playhead, the viewer, the panels).
enum TimelineAction {
    case scrub(CMTime)
    case selectClip(layer: UUID, clip: TimelineClip)
    case renameLayer(UUID, String?)
    case moveLayer(UUID, Int)
    /// Moves a layer to a place among the layers of its kind, after
    /// dragging its header.
    case moveLayerTo(UUID, Int)
    /// A clip's new start, and the layer it moves to if another.
    case moveClip(layer: UUID, clip: UUID, toLayer: UUID?, start: CMTime)
    /// A clip onto a new layer of a kind, at the top.
    case moveClipToNewLayer(layer: UUID, clip: UUID, kind: LayerKind, start: CMTime)
    case applyJointEdit(layer: UUID, clip: UUID, JointEdit)
    case trimClipStart(layer: UUID, clip: UUID, CMTime)
    case trimClipEnd(layer: UUID, clip: UUID, CMTime)
    case editVolume(layer: UUID, (inout AnimatedValue<Double>) -> Void)
    case setTransition(layer: UUID, clip: UUID, TransitionKind, TransitionEdge)
    case removeTransition(layer: UUID, clip: UUID, TransitionEdge)
    case selectTransition(layer: UUID, clip: TimelineClip, TransitionEdge)
    case setTransitionCurve(layer: UUID, clip: UUID, TransitionEdge, TransitionCurve)
    case setTransitionDuration(layer: UUID, clip: UUID, TransitionEdge, CMTime)
    /// Detaches the sound of the given clips on a layer, or of all its
    /// linked clips when nil.
    case detachAudio(layer: UUID, clips: Set<UUID>?)
    /// A layer was selected, which clears any clip selection.
    case selectLayer
    /// Goes into a nested timeline, from its clip.
    case openTimeline(UUID)
    case deleteClip(layer: UUID, clip: UUID)
    case deleteLayer(UUID)
    /// Splits a clip at a timeline time, from the blade.
    case bladeClip(layer: UUID, clip: UUID, at: CMTime)
    /// Slips a clip's footage (positive plays later footage).
    case slipClip(layer: UUID, clip: UUID, by: CMTime)
    /// The clip as a slip drag would leave it, for the viewer to show its
    /// first and last frames; nil when the drag ends.
    case trimPreview(TimelineClip?, TrimPreviewFrames)
    /// Applies a change to the project. It runs before `dispatch` returns,
    /// so what it sets can be read straight after.
    case editProject((inout EditingProject) -> Void)
    /// Shows the effects panel, or hides it.
    case setShowsEffects(Bool)
}
