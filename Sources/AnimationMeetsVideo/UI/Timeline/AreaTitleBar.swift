import SwiftUI

/// The strip naming one of the timeline's areas (Video, Sound, Music). Below
/// the top area it is also the grip for the boundary with the area above:
/// dragging it gives one area's height to the other.
struct AreaTitleBar: View {
    static let height: CGFloat = 18

    let kind: LayerKind
    let layerCount: Int
    let labelColumnWidth: CGFloat
    let isResizable: Bool
    /// The distance dragged down since the drag began.
    let onResize: (CGFloat) -> Void
    let onResizeEnded: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Design.Space.close) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(kind.tone)
                .frame(width: 3, height: 10)
            Text(kind.name.uppercased())
                .font(Design.Typeface.micro.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Design.textSecondary)
            Text("\(layerCount)")
                .font(Design.Typeface.numericMicro)
                .foregroundStyle(Design.textTertiary)
            Spacer(minLength: 0)
            if isResizable {
                Capsule()
                    .fill(isHovering ? Design.textSecondary : Design.textTertiary.opacity(0.5))
                    .frame(width: 24, height: 3)
                    // Centred on the track area, under the grip's pointer.
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, Design.Space.step)
        .frame(height: Self.height)
        .background(Design.Surface.raised.color)
        .overlay(alignment: .top) { Design.hairline.frame(height: 1) }
        .overlay(alignment: .bottom) { Design.bevelLight.frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 && isResizable }
        .pointerStyle(isResizable ? .rowResize : nil)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in onResize(value.translation.height) }
                .onEnded { _ in onResizeEnded() },
            including: isResizable ? .all : .subviews
        )
        .help(isResizable ? "Drag to resize the \(kind.name.lowercased()) area against the one above" : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.name) area, \(layerCount) \(layerCount == 1 ? "layer" : "layers")")
        .accessibilityAddTraits(.isHeader)
    }
}
