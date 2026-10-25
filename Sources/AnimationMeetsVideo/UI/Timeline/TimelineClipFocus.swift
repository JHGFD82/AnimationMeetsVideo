import CoreMedia
import SwiftUI

/// A clip to bring into view, as Find All does with a use picked in it:
/// the timeline zooms to fit it, centers it, and lights it up white for a
/// moment. Each request is new, so picking the same use again shows it
/// again.
struct TimelineClipFocus: Equatable {
    var id = UUID()
    var timelineID: UUID
    var layerID: UUID
    var clipID: UUID
}

extension TimelineView {
    /// The room left either side of a focused clip, as a share of the width.
    private static let focusMargin: CGFloat = 0.1

    /// Shows `focus` if it is on this timeline and not yet shown: zoomed so
    /// the clip fills the tracks but for a margin, as close as the zoom
    /// goes for a short one, with its middle in the middle of the view. Its
    /// area is shown if it was hidden; the area scrolls to it when the
    /// highlight is laid out (`area`).
    func showFocusedClip() {
        guard let focus, focus.id != shownFocusID, focus.timelineID == timelineID,
              let layer = timeline.layer(id: focus.layerID), let clip = layer.clips.first(id: focus.clipID)
        else { return }
        shownFocusID = focus.id
        areaLayout.setShown(layer.kind, true)
        apply(currentViewport.fitting(clip.startOffset.seconds, clip.endOffset.seconds, margin: Self.focusMargin))
        highlightedFocus = focus
    }

    /// The white light over the focused clip, laid out in the tracks' own
    /// coordinates for the layers of `kind`, and nothing if it isn't
    /// among them.
    @ViewBuilder
    func focusHighlight(_ kind: LayerKind, pixelsPerSecond: CGFloat) -> some View {
        let layers = areaLayers(kind)
        if let focus = highlightedFocus, let index = layers.firstIndex(where: { $0.id == focus.layerID }),
           let clip = layers[index].clips.first(id: focus.clipID) {
            ClipFocusHighlight {
                if highlightedFocus?.id == focus.id { highlightedFocus = nil }
            }
            .frame(
                width: max(2, CGFloat(clip.placedDuration.seconds) * pixelsPerSecond),
                height: clipRowHeight(of: layers[index])
            )
            // Also what the area scrolls to.
            .id(focus.id)
            .padding(.leading, CGFloat(clip.startOffset.seconds) * pixelsPerSecond)
            .padding(.top, tops(of: layers)[index])
        }
    }
}

/// A white light over a clip that fades away, then reports it is done.
/// With reduced motion it stays lit for the same time and goes out at once.
struct ClipFocusHighlight: View {
    let onFinished: () -> Void
    @State private var opacity = 0.85

    /// A moment lit, then the fade.
    private static let hold = 0.3
    private static let fade = 1.2

    var body: some View {
        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                if let fade = Design.Motion.respecting(.easeOut(duration: Self.fade).delay(Self.hold)) {
                    withAnimation(fade) { opacity = 0 }
                }
                try? await Task.sleep(for: .seconds(Self.hold + Self.fade))
                onFinished()
            }
    }
}
