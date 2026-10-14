import SwiftUI

/// The two zoom sliders in the timeline's header: time across, and the
/// height of the shown areas' layers. Both are even in ratio, so each step
/// zooms by the same factor.
struct TimelineZoomSliders: View {
    /// 0 fits the whole timeline; 1 is the closest zoom.
    @Binding var horizontal: Double
    /// 0 is the shortest layers; 1 the tallest.
    @Binding var vertical: Double

    var body: some View {
        HStack(spacing: Design.Space.step) {
            slider(
                $horizontal, systemImage: "arrow.left.and.right",
                help: "Zoom time about the playhead (pinch, Option-scroll, - and =)"
            )
            slider(
                $vertical, systemImage: "arrow.up.and.down",
                help: "Layer height in every shown area (pinch up and down, or Option-pinch)"
            )
        }
    }

    private func slider(_ value: Binding<Double>, systemImage: String, help: String) -> some View {
        HStack(spacing: Design.Space.tight) {
            Image(systemName: systemImage)
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.textTertiary)
            Slider(value: value, in: 0...1)
                .controlSize(.mini)
                .frame(width: 84)
        }
        .help(help)
    }
}
