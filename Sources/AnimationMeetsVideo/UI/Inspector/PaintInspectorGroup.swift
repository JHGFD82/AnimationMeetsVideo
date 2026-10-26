import CoreMedia
import SwiftUI

/// How a shape or text is colored and outlined, in the inspector: its Fill,
/// and its Stroke with the stroke's width, edge (which side of the outline
/// it goes), join, cap and dash, as Illustrator's Appearance and Stroke
/// panels offer them: edge, join and cap as icon buttons drawn like the
/// stroke they pick. Each color has a checkbox that leaves it out. Set
/// outright, as `InspectorControlRow` explains; keyframed in the effects
/// panel.
struct PaintInspectorGroup: View {
    let effect: Effect
    /// "Fill & Stroke", or with the effect's name when the clip draws more
    /// than one shape.
    let title: String
    let playhead: PlayheadTime
    let onEdit: ((inout Effect) -> Void) -> Void
    let onSeek: (CMTime) -> Void

    var body: some View {
        let stroke = effect.control(.stroke)
        InspectorGroup(title) {
            InspectorControls(effect: effect, kinds: [.fill, .stroke], playhead: playhead, onEdit: onEdit, onSeek: onSeek)
            // The stroke's shape matters only while there is one.
            if stroke?.enabled ?? false {
                InspectorControls(
                    effect: effect, kinds: [.strokeWidth, .strokeEdge, .strokeJoin, .strokeCap, .dash],
                    playhead: playhead, onEdit: onEdit, onSeek: onSeek
                )
            }
        }
    }
}
