import SwiftUI

/// The Center and Fit chips over the viewer's bottom left corner, each
/// there only while it would do something: Center while the frame isn't
/// centered, Fit (with the zoom now) while the zoom isn't Fit. A view of
/// its own, so a pinch or a scroll redraws only it, not the panel.
struct ViewerFramingChips: View {
    let framing: ViewerFraming

    var body: some View {
        HStack(spacing: Design.Space.close) {
            if !framing.isCentered {
                chip(systemImage: "scope", text: nil) { framing.centerFrame() }
                    .help("Center the frame in the viewer, keeping the zoom (⇧⌘0)")
                    .accessibilityLabel("Center")
            }
            if !framing.isFit {
                chip(systemImage: "arrow.down.right.and.arrow.up.left", text: framing.zoomText) { framing.fit() }
                    .help("Zoom to fit the frame in the viewer (⌘0)")
                    .accessibilityLabel("Fit")
                    .accessibilityValue("\(framing.zoomPercent) percent")
            }
        }
        .padding(Design.Space.group)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func chip(systemImage: String, text: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Design.Space.tight) {
                Image(systemName: systemImage)
                    .font(Design.Typeface.label)
                if let text {
                    Text(text).font(Design.Typeface.numericSmall)
                }
            }
            .foregroundStyle(Design.textPrimary)
            .padding(.horizontal, Design.Space.close)
            .padding(.vertical, 3)
            .beveledChip(fill: Design.Surface.overlay.color, radius: Design.Radius.control, strong: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
