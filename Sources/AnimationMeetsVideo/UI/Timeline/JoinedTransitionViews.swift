import CoreMedia
import SwiftUI

/// A transition joining two clips, drawn over the cut on top of both: the
/// shaded area is its curve, the line the cut. Click to select (and, zoomed
/// in, edit the curve), double-click to open its footage below the layer,
/// right-click for curves, and drop another transition on it to swap kinds.
struct JoinedTransitionBridge: View {
    let joint: TransitionJoint
    let isSelected: Bool
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onSetKind: (TransitionKind) -> Void
    let onSetCurve: (TransitionCurve) -> Void
    let onRemove: () -> Void
    /// The joint after widening by a distance on each side, for the drag.
    let previewWiden: (CMTime) -> TransitionJoint?
    /// Widens it by a distance on each side (narrows when negative).
    let onWiden: (CMTime) -> Void

    @State private var isDropTarget = false
    /// The joint as a side drag in progress leaves it.
    @State private var draft: (widen: CMTime, joint: TransitionJoint)?

    /// As for transitions on one clip, how wide it must be drawn before its
    /// curve can be edited in place.
    private let curveEditingWidth: CGFloat = 80

    var body: some View {
        let joint = draft?.joint ?? self.joint
        let transition = joint.transition
        let x = joint.start.seconds * pixelsPerSecond
        let width = max(6, transition.duration.seconds * pixelsPerSecond)
        let cutX = joint.lead.seconds * pixelsPerSecond
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(0.45))
            TransitionWedge(curve: transition.curve, edge: .leading)
                .fill(Color.white.opacity(isSelected ? 0.32 : 0.22))
            Rectangle()
                .fill(Design.textOnColor.opacity(0.75))
                .frame(width: 1, height: height)
                .offset(x: cutX)
            Image(systemName: transition.kind.systemImage)
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.textOnColor.opacity(0.9))
                .frame(width: width, height: height)
            if isSelected, width >= curveEditingWidth, height >= 30 {
                TransitionCurveEditor(curve: transition.curve, edge: .leading, size: CGSize(width: width, height: height), onChange: onSetCurve)
            }
            sideHandle(atX: 0, outward: -1)
            sideHandle(atX: width, outward: 1)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(isSelected || isDropTarget ? Design.accent : Design.textOnColor.opacity(0.6), lineWidth: isSelected || isDropTarget ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded(onEdit).exclusively(before: TapGesture().onEnded(onSelect)))
        .contextMenu {
            let current = transition.curve.preset
            ForEach(TransitionCurve.Preset.allCases) { preset in
                Button {
                    onSetCurve(TransitionCurve(preset: preset))
                } label: {
                    if current == preset {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
            Divider()
            Button("Edit Footage…", action: onEdit)
            Button("Remove \(transition.kind.name)", action: onRemove)
        }
        .dropDestination(for: TransitionDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            onSetKind(payload.kind)
            return true
        } isTargeted: { isDropTarget = $0 }
        .help("\(transition.kind.name) joining two clips: drag a side to resize it about its center, double-click to adjust its footage")
        .offset(x: x)
    }

    /// A side of the transition: dragging it outward lengthens the
    /// transition by as much on the other side, keeping its center.
    private func sideHandle(atX x: CGFloat, outward: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6, height: height)
            .contentShape(Rectangle())
            .offset(x: x - 3)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let widen = CMTime(seconds: Double(value.translation.width * outward / pixelsPerSecond), preferredTimescale: 600)
                        if let joint = previewWiden(widen) { draft = (widen, joint) }
                    }
                    .onEnded { _ in
                        if let draft { onWiden(draft.widen) }
                        draft = nil
                    }
            )
            .pointerStyle(.columnResize)
    }
}

/// The footage a joining transition draws on, opened under the layer by
/// double-clicking the transition. The top row is the outgoing clip, the
/// bottom the incoming one; the faint parts are their spare footage past
/// the trims, which the transition plays. Drag the transition to move it
/// across the cut, either edge to resize it about its center, and the cut line
/// to roll the cut (trimming one clip as the other grows). Edits keep to
/// the spare footage and are committed when a drag ends.
struct TransitionFootageLane: View {
    let joint: TransitionJoint
    let frameRate: Double
    let outgoingName: String
    let incomingName: String
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let visibleX: ClosedRange<CGFloat>
    let preview: (JointEdit) -> TransitionJoint?
    let onCommit: (JointEdit) -> Void
    /// With the slip tool the cut line slips instead of rolling: its top
    /// half the outgoing clip's footage, its bottom half the incoming clip's.
    let tool: TimelineTool
    /// The clip a slip drag is changing, for the viewer; nil when it ends.
    let onTrimPreview: (TimelineClip?) -> Void

    static let height: CGFloat = 68

    @State private var draft: (edit: JointEdit, joint: TransitionJoint)?

    private let rowHeight: CGFloat = 24
    private let handleWidth: CGFloat = 8

    private var shown: TransitionJoint { draft?.joint ?? joint }

    var body: some View {
        let joint = shown
        let cutX = x(joint.cut)
        let startX = x(joint.start)
        let endX = x(joint.end)
        let topY: CGFloat = 8, bottomY = 8 + rowHeight + 4

        ZStack(alignment: .topLeading) {
            // Outgoing clip, then its spare tail.
            bar(from: x(joint.outgoing.startOffset), to: cutX, y: topY, color: Design.ClipTone.video.color, opacity: 0.45, label: "Out: \(outgoingName)", alignLabel: .trailing)
            bar(from: cutX, to: x(CMTimeAdd(joint.cut, joint.spareTail)), y: topY, color: Design.ClipTone.video.color, opacity: 0.15,
                label: "spare \(joint.spareTail.compactTimecode(frameRate: frameRate))", alignLabel: .leading)
            // Incoming clip's spare head, then the clip.
            bar(from: x(CMTimeSubtract(joint.cut, joint.spareHead)), to: cutX, y: bottomY, color: Design.ClipTone.video.color, opacity: 0.15,
                label: "spare \(joint.spareHead.compactTimecode(frameRate: frameRate))", alignLabel: .trailing)
            bar(from: cutX, to: x(joint.incoming.endOffset), y: bottomY, color: Design.ClipTone.video.color, opacity: 0.45, label: "In: \(incomingName)", alignLabel: .leading)

            // The transition across both rows.
            RoundedRectangle(cornerRadius: 3)
                .fill(Design.accent.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Design.accent, lineWidth: 1.5))
                .frame(width: max(4, endX - startX), height: Self.height - 8)
                .contentShape(Rectangle())
                .offset(x: startX, y: 4)
                .gesture(drag { delta in .place(duration: self.joint.transition.duration, lead: CMTimeSubtract(self.joint.lead, delta)) })
                .help("Drag to move the transition across the cut")
            // Either side resizes it about its center.
            edgeHandle(atX: startX) { delta in .widen(CMTimeSubtract(.zero, delta)) }
            edgeHandle(atX: endX) { delta in .widen(delta) }

            // Like film under a window: dragging right brings earlier frames in.
            if tool == .slip {
                slipHandle(atX: cutX, y: 0, edit: { .slipOut(CMTimeSubtract(.zero, $0)) })
                    .help("Drag to slip the outgoing clip: the cut stays, its footage moves")
                slipHandle(atX: cutX, y: Self.height / 2, edit: { .slipIn(CMTimeSubtract(.zero, $0)) })
                    .help("Drag to slip the incoming clip: the cut stays, its footage moves")
            } else {
                cutHandle(atX: cutX)
            }
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .background(Design.Surface.well.color.opacity(0.7))
    }

    /// The cut, which rolls.
    private func cutHandle(atX cutX: CGFloat) -> some View {
            ZStack {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: Self.height)
                Capsule()
                    .fill(Color.white)
                    .frame(width: 8, height: 18)
            }
            .frame(width: 12, height: Self.height)
            .contentShape(Rectangle())
            .offset(x: cutX - 6)
            .gesture(drag { delta in .roll(delta) })
            .pointerStyle(.columnResize)
            .help("Drag to roll the cut: the transition draws on different footage")
    }

    /// Half of the cut line, for one clip's row, that slips that clip.
    private func slipHandle(atX cutX: CGFloat, y: CGFloat, edit: @escaping (CMTime) -> JointEdit) -> some View {
        ZStack {
            Rectangle()
                .fill(Design.snap)
                .frame(width: 2, height: Self.height / 2)
            Capsule()
                .fill(Design.snap)
                .frame(width: 8, height: 14)
        }
        .frame(width: 12, height: Self.height / 2)
        .contentShape(Rectangle())
        .offset(x: cutX - 6, y: y)
        .gesture(drag(edit))
        .pointerStyle(.columnResize)
    }

    private func x(_ time: CMTime) -> CGFloat {
        time.seconds * pixelsPerSecond
    }

    /// A bar between two times, drawn only where it is on screen.
    private func bar(from minX: CGFloat, to maxX: CGFloat, y: CGFloat, color: Color, opacity: Double, label: String, alignLabel: Alignment) -> some View {
        let drawnMin = max(minX, visibleX.lowerBound - 4)
        let drawnMax = min(maxX, visibleX.upperBound + 4)
        let drawnWidth = max(0, drawnMax - drawnMin)
        return Text(label)
            .font(Design.Typeface.micro)
            .lineLimit(1)
            .foregroundStyle(Design.textSecondary)
            .padding(.horizontal, 4)
            .frame(width: drawnWidth, height: rowHeight, alignment: alignLabel)
            .clipped()
            .background(color.opacity(opacity))
            .overlay(Rectangle().strokeBorder(color.opacity(opacity + 0.3), lineWidth: 0.75))
            .offset(x: drawnMin, y: y)
            .opacity(drawnWidth > 0 ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func edgeHandle(atX x: CGFloat, edit: @escaping (CMTime) -> JointEdit) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: handleWidth, height: Self.height)
            .contentShape(Rectangle())
            .offset(x: x - handleWidth / 2)
            .gesture(drag(edit))
            .pointerStyle(.columnResize)
            .help("Drag to change the transition's length, about its center")
    }

    /// A drag measured in time, previewed through the project's rules and
    /// committed when it ends.
    private func drag(_ edit: @escaping (CMTime) -> JointEdit) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let delta = CMTime(seconds: Double(value.translation.width / pixelsPerSecond), preferredTimescale: 600)
                let change = edit(delta)
                guard let joint = preview(change) else { return }
                draft = (change, joint)
                switch change {
                case .slipOut: onTrimPreview(joint.outgoing)
                case .slipIn: onTrimPreview(joint.incoming)
                case .roll, .place, .widen: break
                }
            }
            .onEnded { _ in
                onTrimPreview(nil)
                if let draft { onCommit(draft.edit) }
                draft = nil
            }
    }
}
