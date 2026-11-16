import AppKit
import SwiftUI

/// The one view laid over the viewer's picture (see docs/viewer-handles.md,
/// "The canvas"). It covers the whole well, so what is on or past the
/// frame's edge can be reached, and is always there: it takes the pinch
/// and the scroll that zoom and move the picture, playing or not.
struct ViewerCanvas: View {
    let framing: ViewerFraming
    let frameSize: CGSize
    /// The timeline's player, whose playing hides the handles.
    var playback: PlaybackModel?
    /// What the handles edit; nil in a viewer that edits nothing.
    var handles: ViewerHandlesSource?
    /// The viewer shows something other than the timeline at the playhead
    /// (a browser skim, a trim preview), which hides the handles.
    var showsOtherPicture = false

    @Environment(\.displayScale) private var displayScale
    /// The pinch's magnification at its last step, which the next is
    /// measured from.
    @State private var pinched: CGFloat?

    /// A pinch or a scroll during a drag is ignored: the drag works in the
    /// frame's pixels as they were mapped when it began.
    private var isDragging: Bool { handles?.state.drag != nil }

    var body: some View {
        GeometryReader { proxy in
            let mapping = framing.mapping(frameSize: frameSize, wellSize: proxy.size, backingScale: displayScale)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
                if let handles, let playback {
                    // Reads the playhead itself, so the panel doesn't.
                    PlayheadReader(playhead: handles.playhead) { time in
                        ViewerHandlesOverlay(
                            source: handles, mapping: mapping, time: time, playback: playback, framing: framing,
                            showsOtherPicture: showsOtherPicture
                        )
                    }
                }
            }
            // On the canvas as a whole, so it works over the handles too.
            .simultaneousGesture(pinch(mapping))
            .background(ScrollWheelMonitor.bothAxes { delta, _ in
                guard !isDragging else { return true }
                // From the framing as it is now: a scroll's events can
                // come faster than this view is drawn again.
                framing.apply((framing.current ?? mapping).scrolled(by: delta))
                return true
            })
            .background(KeyPressMonitor { zoomKey($0) })
        }
    }

    /// Two fingers zoom about where they began: the spot of the picture
    /// there stays there.
    private func pinch(_ mapping: ViewerMapping) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let factor = value.magnification / (pinched ?? 1)
                pinched = value.magnification
                guard factor.isFinite, factor > 0, !isDragging else { return }
                framing.apply((framing.current ?? mapping).zoomed(by: Double(factor), about: value.startLocation))
            }
            .onEnded { _ in pinched = nil }
    }

    /// ⌘= zooms in, as ⌘+ (the View menu's) does.
    private func zoomKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, event.charactersIgnoringModifiers == "=" else { return false }
        framing.zoomIn()
        return true
    }
}
