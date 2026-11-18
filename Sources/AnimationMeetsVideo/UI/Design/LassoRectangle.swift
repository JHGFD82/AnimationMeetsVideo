import SwiftUI

/// The rectangle a lasso drag draws, wherever one picks things: clips in
/// the timeline, keyframes in the effects panel's lanes and on a graph,
/// markers in the Motion Designer. A faint accent fill inside an accent
/// outline, sized to `size`; the caller places it. Drawn for looks alone.
struct LassoRectangle: View {
    let size: CGSize

    var body: some View {
        RoundedRectangle(cornerRadius: Design.Radius.lasso, style: .continuous)
            .fill(Design.accent.opacity(0.12))
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.lasso, style: .continuous)
                    .strokeBorder(Design.accent.opacity(0.9), lineWidth: 1)
            }
            .frame(width: size.width, height: size.height)
            .decorative()
    }
}
