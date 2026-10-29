import CoreMedia
import SwiftUI

/// The transitions on a clip's ends: the wedges that show where each
/// plays, and the handles on their inner sides that change their length.
extension ClipBlockView {
    /// The end whose transition covers `x` (in the clip's row), if any.
    func transitionEdge(atX x: CGFloat, liveX: CGFloat) -> TransitionEdge? {
        let durations = model.clip.effectiveTransitionDurations(lead: model.joinedLead ?? .zero)
        let end = liveX + model.clip.placedDuration.seconds * model.pixelsPerSecond
        if model.clip.transitionIn != nil, model.joinedLead == nil, x >= liveX, x <= liveX + durations.leading.seconds * model.pixelsPerSecond {
            return .leading
        }
        if model.clip.transitionOut != nil, x <= end, x >= end - durations.trailing.seconds * model.pixelsPerSecond {
            return .trailing
        }
        return nil
    }

    /// Shaded wedges over the part of the clip each transition plays in,
    /// shaped by their curves, in the block's drawn coordinates. A selected
    /// one wide enough on screen shows its curve's points to edit.
    func transitionMarks(of shown: TimelineClip, liveX: CGFloat, drawnX: CGFloat, drawnWidth: CGFloat) -> some View {
        let durations = shown.effectiveTransitionDurations(lead: model.joinedLead ?? .zero)
        let liveEnd = liveX + shown.placedDuration.seconds * model.pixelsPerSecond
        let leadingWidth = durations.leading.seconds * model.pixelsPerSecond
        let trailingWidth = durations.trailing.seconds * model.pixelsPerSecond
        return ZStack(alignment: .topLeading) {
            if let transition = shown.transitionIn, model.joinedLead == nil, leadingWidth > 0 {
                transitionMark(transition, edge: .leading, width: leadingWidth)
                    .offset(x: liveX - drawnX)
            }
            if let transition = shown.transitionOut, trailingWidth > 0 {
                transitionMark(transition, edge: .trailing, width: trailingWidth)
                    .offset(x: liveEnd - trailingWidth - drawnX)
            }
        }
        .frame(width: drawnWidth, height: model.height, alignment: .topLeading)
        .clipped()
    }

    private func transitionMark(_ transition: ClipTransition, edge: TransitionEdge, width: CGFloat) -> some View {
        let isSelected = model.selectedTransition == edge
        return ZStack(alignment: .topLeading) {
            TransitionMark(kind: transition.kind, curve: transition.curve, edge: edge, isSelected: isSelected)
                .frame(width: width, height: model.height)
                .contextMenu { transitionMenu(transition, edge: edge) }
            if isSelected, !transition.kind.isAudio, width >= curveEditingWidth, model.height >= 30 {
                TransitionCurveEditor(
                    curve: transition.curve,
                    edge: edge,
                    size: CGSize(width: width, height: model.height),
                    onChange: { handlers.onSetTransitionCurve(edge, $0) }
                )
            }
        }
        .frame(width: width, height: model.height, alignment: .topLeading)
    }

    /// The inner side of each transition on the clip's own ends (not one
    /// joining the clip before): dragging it changes the length, the outer
    /// side staying at the clip's end.
    @ViewBuilder
    func transitionSideHandles(of shown: TimelineClip, liveX: CGFloat) -> some View {
        let durations = shown.effectiveTransitionDurations(lead: model.joinedLead ?? .zero)
        let liveEnd = liveX + shown.placedDuration.seconds * model.pixelsPerSecond
        if let transition = model.clip.transitionIn, model.joinedLead == nil, durations.leading > .zero {
            transitionSideHandle(.leading, transition: transition, atX: liveX + durations.leading.seconds * model.pixelsPerSecond)
        }
        if let transition = model.clip.transitionOut, durations.trailing > .zero {
            transitionSideHandle(.trailing, transition: transition, atX: liveEnd - durations.trailing.seconds * model.pixelsPerSecond)
        }
    }

    private func transitionSideHandle(_ edge: TransitionEdge, transition: ClipTransition, atX x: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6, height: model.height)
            .contentShape(Rectangle())
            .offset(x: x - 3)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // Inward is longer for a way in, shorter for a way out.
                        let delta = timeDelta(edge == .leading ? value.translation.width : -value.translation.width)
                        let duration = handlers.snap(CMTimeAdd(transition.duration, delta))
                        if duration > .zero {
                            transitionDraft = (edge, duration)
                            readout?.showLength(duration, from: transition.duration, pointer: value.location)
                        }
                    }
                    .onEnded { _ in
                        readout?.hide()
                        if let transitionDraft { handlers.onSetTransitionDuration(edge, transitionDraft.duration) }
                        transitionDraft = nil
                    }
            )
            .pointerStyle(.columnResize)
            .help("Drag to change the transition's length")
    }
}

/// Marks where a transition plays on a clip: a wedge whose top edge is the
/// transition's curve, rising over a way in and falling over a way out,
/// with the transition's symbol.
private struct TransitionMark: View {
    let kind: TransitionKind
    let curve: TransitionCurve
    let edge: TransitionEdge
    let isSelected: Bool

    var body: some View {
        ZStack {
            TransitionWedge(curve: curve, edge: edge)
                .fill(Color.white.opacity(isSelected ? 0.34 : 0.22))
            if isSelected {
                TransitionWedge(curve: curve, edge: edge)
                    .stroke(Design.accent, lineWidth: 1)
            }
            Image(systemName: kind.systemImage)
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.textOnColor.opacity(0.85))
        }
        .contentShape(Rectangle())
        .help("\(kind.name): click to select, right-click for curves")
    }
}

/// The area under a transition's curve, down to the clip's bottom edge.
/// The curve is mapped as the curve editor maps it (`TransitionCurveFrame`,
/// its inset included), so the wedge's edge is the very line the editor
/// draws and its points sit on; drawn at the full height, it was steeper.
struct TransitionWedge: Shape {
    let curve: TransitionCurve
    let edge: TransitionEdge

    func path(in rect: CGRect) -> Path {
        // The curve runs left to right in time; under it, the bottom edge.
        var path = TransitionCurveFrame(size: rect.size, edge: edge).path(of: curve)
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
