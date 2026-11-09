import SwiftUI

/// Marks a clip block whose clip is open in the motion designer, which
/// alone may change it meanwhile: fine diagonal hatching across the
/// block, as over something set aside, and a lock in a dark chip at its
/// top right, with the designer's name where the block has room. The
/// chip is dark under light text whatever the clip's colour or the
/// appearance, so it reads on any block. VoiceOver says it in the
/// block's value instead (`accessibilityDescription`).
struct LockedClipMark: View {
    /// A block too narrow for its label shows the lock alone.
    let compact: Bool
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                var stripes = Path()
                let spacing: CGFloat = 7
                var x = -size.height
                while x < size.width {
                    stripes.move(to: CGPoint(x: x, y: size.height))
                    stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += spacing
                }
                context.stroke(stripes, with: .color(.black.opacity(0.22)), lineWidth: 1.5)
            }
            HStack(spacing: 3) {
                Image(systemName: "lock.fill")
                    .font(Design.Typeface.tag)
                if !compact {
                    Text("Motion Designer")
                        .font(Design.Typeface.tag)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.7), in: Capsule())
            .padding(3)
            .help("Open in the Motion Designer. Close it to edit this clip.")
        }
        .frame(maxWidth: .infinity, maxHeight: height, alignment: .topTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
