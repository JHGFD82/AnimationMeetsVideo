import AppKit
import SwiftUI

/// The line under a layer in the layer names column, dragged to make the
/// layer taller or shorter. The keys held say how many layers follow: none
/// for this layer alone, Option for every layer of its area, Option-Shift
/// for every shown layer. Only in the names column, so a drag in the track
/// area always moves clips.
struct LayerResizeDivider: View {
    /// The layer's height when the drag began, and how far it has gone.
    let onChanged: (_ dy: CGFloat, _ flags: NSEvent.ModifierFlags) -> Void
    let onEnded: () -> Void
    /// VoiceOver's increment and decrement, in points.
    let onStep: (CGFloat) -> Void

    static let hitHeight: CGFloat = 6

    var body: some View {
        Color.clear
            .frame(height: Self.hitHeight)
            .contentShape(Rectangle())
            // SwiftUI's pointer, not a pushed NSCursor: a drag let go of
            // outside the strip never heard the hover end, and the pushed
            // cursor stayed everywhere.
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        onChanged(value.translation.height, NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask))
                    }
                    .onEnded { _ in onEnded() }
            )
            .help("Drag to resize the layer. Option: every layer of this kind. Option-Shift: every layer shown.")
            .accessibilityElement()
            .accessibilityLabel("Layer height")
            .accessibilityAdjustableAction { direction in
                onStep(direction == .increment ? 8 : -8)
            }
    }
}
