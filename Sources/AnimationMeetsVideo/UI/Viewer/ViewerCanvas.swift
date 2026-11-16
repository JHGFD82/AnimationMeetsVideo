import AppKit
import SwiftUI

/// The one view laid over the viewer's picture (see docs/viewer-handles.md,
/// "The canvas"). It covers the whole well, so what is on or past the
/// frame's edge can be reached, and is always there: it takes the pinch
/// and the scroll that zoom and move the picture, playing or not.
struct ViewerCanvas: View {
    let framing: ViewerFraming
    let frameSize: CGSize

    @Environment(\.displayScale) private var displayScale
    /// The pinch's magnification at its last step, which the next is
    /// measured from.
    @State private var pinched: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let mapping = framing.mapping(frameSize: frameSize, wellSize: proxy.size, backingScale: displayScale)
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(pinch(mapping))
                .background(ScrollWheelMonitor.bothAxes { delta, _ in
                    // From the framing as it is now: a scroll's events can
                    // come faster than this view is drawn again.
                    framing.apply((framing.current ?? mapping).scrolled(by: delta))
                    return true
                })
                .background(KeyPressMonitor { zoomKey($0) })
                .accessibilityHidden(true)
        }
    }

    /// Two fingers zoom about where they began: the spot of the picture
    /// there stays there.
    private func pinch(_ mapping: ViewerMapping) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let factor = value.magnification / (pinched ?? 1)
                pinched = value.magnification
                guard factor.isFinite, factor > 0 else { return }
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
