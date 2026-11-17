import SwiftUI

/// The composition, sized and placed in the well by the viewer's zoom and
/// place (`ViewerMapping`): at Fit, inset from the well with a cut edge
/// so the frame boundary reads whatever the content is. Sized, not put
/// through a scale effect, and deliberately no drop shadow: either would
/// force the video surface through an offscreen pass on every frame, and
/// the hairline already does the job. Past 100% the picture's pixels are
/// enlarged, not drawn again. A view of its own, so a pinch or a scroll
/// redraws only this.
struct FramedPicture: View {
    let playback: PlaybackModel
    let frameRate: Double
    let frameSize: CGSize
    let framing: ViewerFraming
    /// The hairline round the frame; left off where nothing is around it
    /// to tell it from (the external display's black).
    var showsEdge = true
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // Read here, not only in the reader below, whose reads don't draw
        // the picture again: a zoom or a scroll must (as `ViewerCanvas`).
        let _ = (framing.zoom, framing.center)
        GeometryReader { proxy in
            let mapping = framing.mapping(frameSize: frameSize, wellSize: proxy.size, backingScale: displayScale)
            let rect = mapping.pictureRect
            let _ = framing.note(mapping)
            ViewerPicture(playback: playback, frameRate: frameRate)
                .overlay {
                    Rectangle()
                        .strokeBorder(Color.white.opacity(showsEdge ? 0.08 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .position(x: rect.midX, y: rect.midY)
        }
        // Another frame size starts again from Fit.
        .onChange(of: frameSize) { framing.fit() }
    }
}

/// The player's picture, with the time as its accessibility value. A view
/// of its own so following the time rebuilds only this.
private struct ViewerPicture: View {
    let playback: PlaybackModel
    let frameRate: Double

    var body: some View {
        ViewerLayerView(display: playback.display)
            .accessibilityElement()
            .accessibilityLabel("Viewer")
            .accessibilityValue(playback.currentTime.timecode(frameRate: frameRate))
            .accessibilityAddTraits(.isImage)
    }
}
