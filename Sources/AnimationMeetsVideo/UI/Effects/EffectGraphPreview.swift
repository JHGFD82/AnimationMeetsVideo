import SwiftUI

/// An effect's graph drawn small under its header in the effects panel
/// (Audio Keys' box): a picture of what it does, not a place to edit it.
/// A click, or Space or Return with it focused, opens the full graph,
/// where it is edited.
struct EffectGraphPreview<Graph: View>: View {
    /// The effect's name, for the button's label and tip.
    let name: String
    /// Opens the full graph; nil leaves the graph a picture only.
    let onOpen: (() -> Void)?
    @ViewBuilder let graph: () -> Graph

    @State private var isHovered = false

    /// The height it takes in the effects panel.
    static var height: CGFloat { 72 }

    var body: some View {
        Button { onOpen?() } label: {
            graph()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .background(Color.black.opacity(0.18))
                .overlay(alignment: .topTrailing) {
                    if onOpen != nil {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(Design.Typeface.glyphTiny)
                            .foregroundStyle(isHovered ? Design.textPrimary : Design.textTertiary)
                            .padding(4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Design.bevelEdge, lineWidth: 0.5)
                }
                .overlay {
                    if isHovered {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Design.textTertiary, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpen == nil)
        .onHover { isHovered = $0 && onOpen != nil }
        .help(onOpen == nil ? "" : "Open \(name)'s graph to edit it")
        .accessibilityLabel("\(name) graph")
        .accessibilityHint(onOpen == nil ? "" : "Opens the graph to edit it")
        .padding(.leading, EffectsPanelMetrics.controlIndent)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
    }
}
