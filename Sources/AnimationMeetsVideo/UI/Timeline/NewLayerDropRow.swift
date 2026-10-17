import SwiftUI

/// The slim row under an area's layers: scenes dropped here go on a new
/// layer of the area's kind at the drop time. It says so while something
/// is dragged over it, and is otherwise empty space.
struct NewLayerDropRow: View {
    let height: CGFloat
    let kind: LayerKind
    let onDrop: ([MediaDragPayload], CGFloat) -> Bool

    @State private var isTargeted = false

    var body: some View {
        Text(isTargeted ? "Drop here for a new \(kind.name.lowercased()) layer" : "")
            .font(Design.Typeface.micro)
            .foregroundStyle(Design.accent)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(isTargeted ? Design.accent.opacity(0.14) : .clear)
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        .strokeBorder(Design.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .contentShape(Rectangle())
            .editorAnimation(Design.Motion.select, value: isTargeted)
            .dropDestination(for: MediaDragPayload.self) { payloads, location in
                onDrop(payloads, location.x)
            } isTargeted: { isTargeted = $0 }
    }
}
