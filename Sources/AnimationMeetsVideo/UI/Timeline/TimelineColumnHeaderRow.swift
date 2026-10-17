import SwiftUI

/// Labels the per-layer columns, beside the ruler — currently just
/// number/name, but reserved as the home for upcoming per-layer option
/// controls (visibility, lock, etc.).
struct TimelineColumnHeaderRow: View {
    let height: CGFloat

    var body: some View {
        HStack(spacing: Design.Space.close) {
            Color.clear.frame(width: 12)
            Text("#")
                .frame(width: 18, alignment: .trailing)
            Text("Name")
            Spacer()
        }
        .font(Design.Typeface.micro)
        .foregroundStyle(Design.textTertiary)
        .padding(.horizontal, Design.Space.step)
        .padding(.bottom, Design.Space.tight)
        .frame(height: height, alignment: .bottomLeading)
    }
}
