import CoreMedia
import SwiftUI

/// How a shape or text is colored and outlined, in the inspector: its Fill,
/// and its Stroke with the stroke's width, edge (which side of the outline
/// it goes), join, cap and dash, as Illustrator's Appearance and Stroke
/// panels offer them: edge, join and cap as icon buttons drawn like the
/// stroke they pick. Each color has a checkbox that leaves it out, and on
/// a shape a menu that paints it with a gradient instead, its stops under
/// it (`GradientEditor`, docs/gradients.md). Set
/// outright, as `InspectorControlRow` explains; keyframed in the effects
/// panel.
///
/// A Stroke effect's group is the same without the Fill (`showsFill`
/// off), so the two offer the same stroke.
struct PaintInspectorGroup: View {
    let effect: Effect
    /// "Fill & Stroke", or with the effect's name when the clip draws more
    /// than one shape.
    let title: String
    var showsFill = true
    let playhead: PlayheadTime
    let onEdit: ((inout Effect) -> Void) -> Void
    let onSeek: (CMTime) -> Void

    var body: some View {
        let stroke = effect.control(.stroke)
        let colors: [ControlKind] = showsFill ? [.fill, .stroke] : [.stroke]
        InspectorGroup(title, rowsOf: effect.id, controls: (colors + EffectKind.strokeShapeControls).compactMap { effect.control($0)?.id }) {
            InspectorControls(
                effect: effect, kinds: colors, playhead: playhead, offersGradients: true,
                onEdit: onEdit, onSeek: onSeek
            )
            // The stroke's shape matters only while there is one.
            if stroke?.enabled ?? false {
                InspectorControls(
                    effect: effect, kinds: EffectKind.strokeShapeControls,
                    playhead: playhead, onEdit: onEdit, onSeek: onSeek
                )
            }
            // A shape's own group says so already.
            if !showsFill, !effect.enabled {
                Text("Turned off in the effects panel, so it draws nothing.")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
            }
        }
    }
}
