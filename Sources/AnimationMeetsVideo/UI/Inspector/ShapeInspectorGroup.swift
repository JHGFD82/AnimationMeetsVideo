import CoreMedia
import SwiftUI

/// A shape effect's own settings in the inspector (see
/// docs/graphic-layers.md, "Shapes"): a rectangle's size and corners, a
/// star's points and radii, its position; or for a Stroke effect, the
/// stroke it draws. A drawn shape's fill and stroke follow in a group of
/// their own (`PaintInspectorGroup`), as a Text effect's settings are in
/// `TextInspectorGroup`.
///
/// Set outright, not keyframed (that is the effects panel's), except for a
/// Text Animator: it exists to animate, so its rows keep the stopwatch and
/// keyframe buttons. Driven by the `Effect` it is given alone.
struct ShapeInspectorGroup: View {
    let effect: Effect
    let playhead: PlayheadTime
    let onEdit: ((inout Effect) -> Void) -> Void
    let onSeek: (CMTime) -> Void

    var body: some View {
        // A Stroke effect is all stroke; a shape's paint has its own group.
        let kinds = effect.kind == .stroke
            ? effect.kind.controlKinds
            : effect.kind.controlKinds.filter { !EffectKind.paintControls.contains($0) }
        InspectorGroup(effect.displayName) {
            InspectorControls(
                effect: effect, kinds: kinds, playhead: playhead, keyframing: effect.kind == .textAnimator, onEdit: onEdit, onSeek: onSeek
            )
            if !effect.enabled {
                Text("Turned off in the effects panel, so it draws nothing.")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
            }
        }
    }
}
