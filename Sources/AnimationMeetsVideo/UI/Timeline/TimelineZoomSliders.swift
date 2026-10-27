import SwiftUI

/// The two zoom sliders in the timeline's header: time across, and the
/// height of the shown areas' layers. Both are even in ratio, so each step
/// zooms by the same factor.
struct TimelineZoomSliders: View {
    /// 0 fits the whole timeline; 1 is the closest zoom.
    @Binding var horizontal: Double
    /// 0 is the shortest layers; 1 the tallest.
    @Binding var vertical: Double
    /// Whether the layer height slider is being dragged: true as a drag
    /// starts, false as it ends.
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: Design.Space.step) {
            ZoomSlider(
                fraction: $horizontal, label: "Time zoom",
                help: "Zoom time about the playhead (pinch, Option-scroll, - and =)"
            )
            ZoomSlider(
                fraction: $vertical, label: "Layer height", axis: .vertical,
                help: "Layer height in every shown area (pinch up and down, or Option-pinch)",
                onEditingChanged: onEditingChanged
            )
        }
    }
}
