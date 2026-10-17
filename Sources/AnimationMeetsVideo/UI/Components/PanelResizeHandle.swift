import AppKit
import SwiftUI

/// A strip along one edge of a side panel that resizes the panel by
/// dragging. `edge` is the panel's edge the strip sits on: a panel on the
/// left of the window has it on its trailing edge, one on the right on its
/// leading edge, so dragging away from the panel widens it either way.
struct PanelResizeHandle: View {
    @Binding var width: Double
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let edge: HorizontalEdge
    let help: String
    @State private var startWidth: Double?
    @State private var showsCursor = false

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                // Pushed once and popped once, also when a drag ends outside.
                if inside, !showsCursor {
                    NSCursor.resizeLeftRight.push()
                    showsCursor = true
                } else if !inside, showsCursor, startWidth == nil {
                    NSCursor.pop()
                    showsCursor = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        let change = Double(value.translation.width) * (edge == .leading ? -1 : 1)
                        width = Self.clamped(start + change, min: minWidth, max: maxWidth)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .help(help)
            .accessibilityElement()
            .accessibilityLabel(help)
            .accessibilityValue("\(Int(width.rounded())) points")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 20.0 : -20.0
                width = Self.clamped(width + step, min: minWidth, max: maxWidth)
            }
    }

    static func clamped(_ width: Double, min: CGFloat, max: CGFloat) -> Double {
        Swift.min(Swift.max(width, Double(min)), Double(Swift.max(min, max)))
    }
}
