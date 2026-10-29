import SwiftUI

/// The strip under a tone graph's curve with a thumb under each of its
/// edges, its first and last points, which can't be deleted or dragged on
/// the plot: dragging a thumb moves that edge across, keeping its tone.
/// The thumbs line up with the graph's plot, as `layout` places it, in the
/// strip's own space.
///
/// VoiceOver reaches each thumb as an element of its own, which adjusting
/// moves; the keyboard moves an edge by picking its point on the graph.
struct ToneCurveEdgeSlider: View {
    enum Edge { case left, right }

    /// The edges' tones across.
    let left: Double
    let right: Double
    let layout: ToneGraphLayout
    let tint: Color
    /// The edge whose point is picked on the graph, outlined.
    var picked: Edge?
    var isFocused = false
    /// The drag's thumb moved by `change` tones since the drag began.
    let onDrag: (Edge, Double) -> Void
    let onDragEnded: () -> Void
    /// An edge moved by a step, as one edit.
    let onNudge: (Edge, Double) -> Void
    /// Its name in VoiceOver ("RGB curve").
    let name: String

    @State private var dragging: Edge?

    /// The height it takes under the plot.
    static let height: CGFloat = 12

    /// A hundredth of the tones per VoiceOver adjustment.
    private static let nudge = 0.01

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in draw(in: &context, size: size) }
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .help("Drag a thumb to move the curve's left or right edge")
                .accessibilityHidden(true)
            thumbElement(.left, at: left)
            thumbElement(.right, at: right)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let edge = dragging ?? nearestEdge(to: value.startLocation.x)
                dragging = edge
                onDrag(edge, Double(value.translation.width / max(layout.plot.width, 1)))
            }
            .onEnded { _ in
                guard dragging != nil else { return }
                dragging = nil
                onDragEnded()
            }
    }

    /// The thumb a drag from `x` takes: the nearer one, or the one on the
    /// side of both that `x` is on.
    private func nearestEdge(to x: CGFloat) -> Edge {
        let tone = layout.tone(atX: x)
        if tone <= left { return .left }
        if tone >= right { return .right }
        return tone - left <= right - tone ? .left : .right
    }

    private func percent(_ tone: Double) -> String { NumericExpression.format(tone * 100, maxFractionDigits: 1) + "%" }

    private func thumbElement(_ edge: Edge, at tone: Double) -> some View {
        Color.clear
            .frame(width: 12, height: Self.height)
            .position(x: layout.x(tone), y: Self.height / 2)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("\(name) \(edge == .left ? "left" : "right") edge")
            .accessibilityValue("in \(percent(tone))")
            .accessibilityAdjustableAction { direction in
                onNudge(edge, direction == .increment ? Self.nudge : -Self.nudge)
            }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let plot = layout.plot
        let track: CGFloat = 2
        context.fill(Path(CGRect(x: plot.minX, y: 0, width: plot.width, height: track)), with: .color(Color.white.opacity(0.14)))
        let from = layout.x(left), to = layout.x(right)
        context.fill(Path(CGRect(x: from, y: 0, width: max(to - from, 0), height: track)), with: .color(tint.opacity(0.7)))
        for (edge, x) in [(Edge.left, from), (.right, to)] {
            // A triangle pointing up at the edge it moves.
            let thumb = Path { path in
                path.move(to: CGPoint(x: x, y: track))
                path.addLine(to: CGPoint(x: x + 5, y: size.height - 1))
                path.addLine(to: CGPoint(x: x - 5, y: size.height - 1))
                path.closeSubpath()
            }
            context.fill(thumb, with: .color(tint))
            let isPicked = edge == picked || edge == dragging
            context.stroke(thumb, with: .color(isPicked ? (isFocused ? Design.accent : Design.textSecondary) : Color.black.opacity(0.6)),
                           lineWidth: isPicked ? 1.5 : 1)
        }
    }
}
