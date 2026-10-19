import SwiftUI

/// Where a dragged thing would go: an accent line between rows (or, on
/// the timeline, down the edge a clip would land at), with a ring at its
/// start, as the Mac draws a list's drop position.
struct InsertionLine: View {
    var axis: Axis = .horizontal

    var body: some View {
        let ring: CGFloat = 7
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
        layout {
            Circle()
                .strokeBorder(Design.accent, lineWidth: 2)
                .frame(width: ring, height: ring)
            Design.accent
                .frame(width: axis == .horizontal ? nil : 2, height: axis == .horizontal ? 2 : nil)
        }
        .frame(width: axis == .horizontal ? nil : ring, height: axis == .horizontal ? ring : nil)
        .decorative()
    }
}
