import SwiftUI

/// The shapes a new shape layer can start with, from the shape button in
/// the timeline's header: one row each, which adds the layer at the
/// playhead (see docs/graphic-layers.md, "Shapes").
struct NewShapePopover: View {
    let onAdd: (EffectKind) -> Void

    var body: some View {
        PopoverFrame(width: Design.PopoverWidth.compact, spacing: 2) {
            Text("New Shape Layer")
                .font(Design.Typeface.groupTitle)
                .foregroundStyle(Design.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, Design.Space.tight)
            ForEach(EffectKind.all.filter(\.drawsShape)) { kind in
                Button {
                    onAdd(kind)
                } label: {
                    Label(kind.name, systemImage: kind.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                // Its own style, not the header's icon buttons'.
                .buttonStyle(.borderless)
                .help(kind == .text
                      ? "Add a text layer at the playhead; type its words in the inspector"
                      : "Add a shape layer with a \(kind.name.lowercased()) at the playhead")
            }
        }
    }
}
