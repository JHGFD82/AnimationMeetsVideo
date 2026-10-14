import CoreMedia
import SwiftUI

extension EditingProject {
    /// A layer's name as shown in the timeline: its own name, else "Video N"
    /// or "Audio N", counting layers of its kind from the top. Footage names
    /// made poor defaults: a layer outlives its first clip, and several
    /// layers cut from one file all read the same.
    func displayName(of layer: TimelineLayer, in timeline: Timeline) -> String {
        if let customName = layer.customName, !customName.isEmpty { return customName }
        let isAudio = isAudioOnly(layer)
        let sameKind = timeline.layers.filter { isAudioOnly($0) == isAudio }
        let number = (sameKind.firstIndex { $0.id == layer.id } ?? 0) + 1
        return "\(isAudio ? "Audio" : "Video") \(number)"
    }

    /// Layers holding only sound are audio layers; empty ones count as video,
    /// since that is what most layers become.
    private func isAudioOnly(_ layer: TimelineLayer) -> Bool {
        !layer.clips.isEmpty && !layer.isVisual(in: self)
    }
}

struct LayerHeaderRow: View {
    let number: Int
    let layer: TimelineLayer
    /// The layer's custom name, or its default. See `displayName(of:in:)`.
    let displayName: String
    let height: CGFloat
    let canMoveUp: Bool
    let canMoveDown: Bool
    /// Nil for layers without transform properties (audio), which get no arrow.
    let isExpanded: Bool?
    let onToggleExpanded: () -> Void
    /// Nil for layers with no video still carrying its sound.
    let isAudioExpanded: Bool?
    let onToggleAudio: () -> Void
    let onDetachAudio: () -> Void
    let onRename: (String?) -> Void
    let onMove: (Int) -> Void
    /// Dragging the header up or down reorders the layers; these get the
    /// vertical distance dragged.
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void
    /// Selected by clicking the header; Delete then removes the layer.
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isEditingName = false
    @State private var draftName: String = ""
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let isExpanded {
                    Button(action: onToggleExpanded) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide transform properties" : "Show transform properties (P, S, R, T)")
                } else {
                    Color.clear
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Design.textTertiary)
            .frame(width: 12)
            Text("\(number)")
                .font(Design.Typeface.numericSmall)
                .foregroundStyle(Design.textTertiary)
                .frame(width: 18, alignment: .trailing)
            if isEditingName {
                TextField(displayName, text: $draftName)
                    .font(Design.Typeface.label)
                    .textFieldStyle(.plain)
                    .focused($isNameFieldFocused)
                    .onSubmit { commitRename() }
                    .onAppear { isNameFieldFocused = true }
                    // onSubmit only fires on Return — clicking away to end
                    // editing without pressing Return previously left the
                    // field stuck open and never fell back to the footage
                    // name when left blank. Committing on focus-loss too
                    // fixes that.
                    .onChange(of: isNameFieldFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(displayName)
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textPrimary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        draftName = layer.customName ?? ""
                        isEditingName = true
                    }
            }
            Spacer(minLength: 0)
            if let isAudioExpanded {
                Button(action: onToggleAudio) {
                    Image(systemName: "waveform")
                        .font(Design.Typeface.label)
                        .foregroundStyle(isAudioExpanded ? Design.accent : Design.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isAudioExpanded ? "Hide linked audio" : "Show linked audio")
            }
        }
        .padding(.horizontal, Design.Space.step)
        .frame(height: height, alignment: .leading)
        .selectedRow(isSelected)
        .editorAnimation(Design.Motion.select, value: isSelected)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in onDragChanged(value.translation.height) }
                .onEnded { value in onDragEnded(value.translation.height) }
        )
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .help("Click to select, then Delete to remove the layer. Drag to reorder layers.")
        .contextMenu {
            Button("Move Layer Up") { onMove(-1) }
                .disabled(!canMoveUp)
            Button("Move Layer Down") { onMove(1) }
                .disabled(!canMoveDown)
            if let isAudioExpanded {
                Divider()
                Button(isAudioExpanded ? "Hide Linked Audio" : "Show Linked Audio", action: onToggleAudio)
                Button("Detach Audio", action: onDetachAudio)
            }
            Divider()
            Button("Delete Layer", role: .destructive, action: onDelete)
        }
    }

    private func commitRename() {
        guard isEditingName else { return }
        onRename(draftName.isEmpty ? nil : draftName)
        isEditingName = false
    }
}

/// Where a clip being dragged will land, and what moves aside for it.
struct ClipMovePreview: Equatable {
    var start: CMTime
    /// Nil when it stays on its own layer.
    var layerID: UUID?
    /// How far the target layer's row is below the clip's own.
    var offsetY: CGFloat
    /// The clips on the target layer moving right to make room, by id.
    var pushed: [UUID: PushedClip] = [:]
}

/// A clip moving right to make room for one dragged in front of it.
struct PushedClip: Equatable {
    var from: CMTime
    var to: CMTime
}

struct LayerClipRow: View {
    let layer: TimelineLayer
    let project: EditingProject
    let timelineID: UUID
    let selection: TimelineSelection?
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let height: CGFloat
    /// The on-screen part of the row, in its own x coordinates.
    let visibleX: ClosedRange<CGFloat>
    let onSelectClip: (TimelineClip) -> Void
    /// Where a clip dragged by `dy` points and asked to start at a time
    /// lands: on another layer when dragged onto one with room, else nil.
    let resolveMove: (TimelineClip, CGFloat, CMTime) -> ClipMovePreview?
    /// Moves a clip to a start time, and to another layer when given.
    let onMoveClip: (UUID, UUID?, CMTime) -> Void
    let onDraggingClip: (Bool) -> Void
    /// Clips on this layer moving aside for a clip being dragged, drawn
    /// where they will go until the move lands.
    let pushed: [UUID: PushedClip]
    /// Hears what a drag in progress pushes, and empty when it ends.
    let onPushPreview: ([UUID: PushedClip]) -> Void
    let onDropScenes: ([SceneDragPayload], CMTime) -> Bool
    let onEditJoint: (UUID) -> Void
    let onTrimClipStart: (UUID, CMTime) -> Void
    let onTrimClipEnd: (UUID, CMTime) -> Void
    let onSetTransition: (UUID, TransitionKind, TransitionEdge) -> Void
    let onRemoveTransition: (UUID, TransitionEdge) -> Void
    let onSelectTransition: (TimelineClip, TransitionEdge) -> Void
    let onSetTransitionCurve: (UUID, TransitionEdge, TransitionCurve) -> Void
    let onDetachAudio: (UUID) -> Void
    let tool: TimelineTool
    /// Rounds a time onto the timeline's frames.
    let snap: (CMTime) -> CMTime
    let onBlade: (UUID, CMTime) -> Void
    /// Slips a clip's footage by a time (positive plays later footage).
    let onSlip: (UUID, CMTime) -> Void
    /// What edges snap to, or nil with snapping off, and how close they
    /// must come.
    let snapTargets: SnapTargets?
    let snapTolerance: CMTime
    /// Where a drag snapped, to draw; nil when it didn't or ended.
    let onSnapIndicator: (CMTime?) -> Void
    let onTrimPreview: (TimelineClip?) -> Void
    /// An edit of the joint at the start of a clip.
    let onApplyJointEdit: (UUID, JointEdit) -> Void
    let onSetTransitionDuration: (UUID, TransitionEdge, CMTime) -> Void

    /// While a slip shortens a clip: how far the clips after it move in.
    private struct FollowerShift: Equatable {
        var clipID: UUID
        var after: CMTime
        var shift: CMTime
    }

    @State private var followerShift: FollowerShift?
    /// The clip lifted by a move drag, drawn above its neighbors.
    @State private var liftedClipID: UUID?

    private func shiftX(of clip: TimelineClip) -> CGFloat {
        // A push applies only while the clip is still where it was: once
        // the move lands it is already there, and shifting it again would
        // show it twice as far for a frame.
        if let push = pushed[clip.id], clip.startOffset == push.from {
            return CMTimeSubtract(push.to, push.from).seconds * pixelsPerSecond
        }
        guard let followerShift, clip.id != followerShift.clipID, clip.startOffset >= followerShift.after else { return 0 }
        return followerShift.shift.seconds * pixelsPerSecond
    }

    /// A slip drag's draft: the viewer shows its first and last frames, and
    /// when it shortens the clip the clips after it follow on screen until
    /// the edit arrives.
    private func slipDraft(of clip: TimelineClip, _ draft: TimelineClip?, committing: Bool) {
        if let draft {
            followerShift = FollowerShift(clipID: clip.id, after: clip.endOffset, shift: CMTimeSubtract(draft.endOffset, clip.endOffset))
            onTrimPreview(draft)
        } else {
            onTrimPreview(nil)
            if !committing { followerShift = nil }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layer.clips) { clip in
                let isSelected = selection?.layerID == layer.id && selection?.timelineClipID == clip.id
                let info = project.resolvedInfo(for: clip.source)
                let joinedLead = project.joinedLead(of: clip, among: layer.clips)
                ClipBlockView(
                    clip: clip,
                    info: info,
                    typeColor: Design.ClipTone.of(info, streams: clip.streams).color,
                    hasLinkedAudio: project.hasLinkedAudio(clip),
                    acceptsTransitions: project.playsVideo(clip),
                    joinedLead: joinedLead,
                    isSelected: isSelected,
                    selectedTransition: isSelected ? selection?.transitionEdge : nil,
                    pixelsPerSecond: pixelsPerSecond,
                    height: height,
                    visibleX: visibleX,
                    resolveMove: { start, dy in resolveMove(clip, dy, start) },
                    resolveTrimStart: { project.resolvedTrimStart(of: clip.id, in: timelineID, layer: layer.id, to: $0) },
                    resolveTrimEnd: { project.resolvedTrimEnd(of: clip.id, in: timelineID, layer: layer.id, to: $0) },
                    onSelect: { onSelectClip(clip) },
                    onMove: { newStart, targetLayerID in onMoveClip(clip.id, targetLayerID, newStart) },
                    onDragging: { dragging in
                        liftedClipID = dragging ? clip.id : nil
                        onDraggingClip(dragging)
                    },
                    onMovePreview: { onPushPreview($0?.pushed ?? [:]) },
                    onTrimStart: { newTrimStart in onTrimClipStart(clip.id, newTrimStart) },
                    onTrimEnd: { newTrimEnd in onTrimClipEnd(clip.id, newTrimEnd) },
                    onSetTransition: { kind, edge in onSetTransition(clip.id, kind, edge) },
                    onRemoveTransition: { edge in onRemoveTransition(clip.id, edge) },
                    onSelectTransition: { edge in onSelectTransition(clip, edge) },
                    onSetTransitionCurve: { edge, curve in onSetTransitionCurve(clip.id, edge, curve) },
                    onDetachAudio: { onDetachAudio(clip.id) },
                    tool: tool,
                    snap: snap,
                    onBlade: { time in onBlade(clip.id, time) },
                    resolveSlip: { project.resolvedSlip(of: clip.id, in: timelineID, layer: layer.id, by: $0) },
                    onSlip: { delta in onSlip(clip.id, delta) },
                    onSlipDraft: { draft, committing in slipDraft(of: clip, draft, committing: committing) },
                    snapTime: { snapTargets?.nearest(to: $0, within: snapTolerance, excluding: clip.id) },
                    snapSpan: { start, duration in
                        snapTargets?.snappedStart(start, duration: duration, within: snapTolerance, excluding: clip.id)
                    },
                    onSnapIndicator: onSnapIndicator,
                    onSetTransitionDuration: { edge, duration in onSetTransitionDuration(clip.id, edge, duration) }
                )
                .offset(x: shiftX(of: clip))
                // Clips slide aside as a drag makes room, but not when the
                // move lands: then the shift and the new start cancel out.
                .animation(liftedClipID == nil ? nil : Design.Motion.respecting(Design.Motion.panel), value: shiftX(of: clip))
                .zIndex(liftedClipID == clip.id ? 1 : 0)
            }
            // Transitions joining two clips sit over the cut, on top of both.
            ForEach(layer.clips) { clip in
                if let joint = project.joint(at: clip.id, in: timelineID, layer: layer.id) {
                    let isSelected = selection?.layerID == layer.id && selection?.timelineClipID == clip.id
                        && selection?.transitionEdge == .leading
                    JoinedTransitionBridge(
                        joint: joint,
                        isSelected: isSelected,
                        pixelsPerSecond: pixelsPerSecond,
                        height: height,
                        onSelect: { onSelectTransition(clip, .leading) },
                        onEdit: { onEditJoint(clip.id) },
                        onSetKind: { kind in onSetTransition(clip.id, kind, .leading) },
                        onSetCurve: { curve in onSetTransitionCurve(clip.id, .leading, curve) },
                        onRemove: { onRemoveTransition(clip.id, .leading) },
                        previewWiden: { widen in
                            var copy = project
                            copy.applyJointEdit(.widen(widen), at: clip.id, in: timelineID, layer: layer.id)
                            return copy.joint(at: clip.id, in: timelineID, layer: layer.id)
                        },
                        onWiden: { widen in onApplyJointEdit(clip.id, .widen(widen)) }
                    )
                    .offset(x: shiftX(of: clip))
                }
            }
        }
        .onChange(of: layer.clips) { _, _ in followerShift = nil }
        // offset() shifts rendering without changing the size a view reports
        // to its parent, so without an explicit width here the row would
        // size itself to its (un-offset) widest clip rather than spanning
        // the full timeline — leaving every clip's absolute x-position
        // anchored to the wrong origin instead of true timeline time 0.
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        // Scenes dropped on a layer go onto it where they were dropped.
        .dropDestination(for: SceneDragPayload.self) { payloads, location in
            onDropScenes(payloads, CMTime(seconds: max(0, Double(location.x / pixelsPerSecond)), preferredTimescale: 600))
        }
    }
}

// Clips are coloured by what they are — see `Design.ClipTone`, which keeps
// the three tones at matched lightness so a mixed timeline reads as one
// material in three tints rather than as three competing colours. Image and
// text layers will slot into that same enum once they exist.

/// A single clip block, positioned by absolute offset (not sequential flow)
/// so a clip's on-screen position always matches its `startOffset`.
/// Draggable in its middle to move it in time, and draggable at either edge
/// to non-destructively trim `trimStart`/`trimEnd`. While dragging, the
/// block shows where the drop will land (on a frame, clear of its
/// neighbors) rather than following the pointer freely, and trimming adds
/// a translucent, outlined ghost of the clip's extent before the trim.
struct ClipBlockView: View {
    let clip: TimelineClip
    let info: ResolvedClipInfo?
    let typeColor: Color
    /// Shows a sound badge, and offers to detach the sound.
    let hasLinkedAudio: Bool
    /// Clips with pictures take transitions dropped from the panel.
    let acceptsTransitions: Bool
    /// Set when the clip's way in joins it to the clip before: that
    /// transition is drawn over the cut by the row instead.
    let joinedLead: CMTime?
    let isSelected: Bool
    /// The transition selected on this clip, which shows its curve's points
    /// when there is room.
    let selectedTransition: TransitionEdge?
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    let visibleX: ClosedRange<CGFloat>
    let resolveMove: (CMTime, CGFloat) -> ClipMovePreview?
    let resolveTrimStart: (CMTime) -> TimelineClip?
    let resolveTrimEnd: (CMTime) -> TimelineClip?
    let onSelect: () -> Void
    let onMove: (CMTime, UUID?) -> Void
    let onDragging: (Bool) -> Void
    /// Hears where a move drag will land, and nil when it ends.
    let onMovePreview: (ClipMovePreview?) -> Void
    let onTrimStart: (CMTime) -> Void
    let onTrimEnd: (CMTime) -> Void
    let onSetTransition: (TransitionKind, TransitionEdge) -> Void
    let onRemoveTransition: (TransitionEdge) -> Void
    let onSelectTransition: (TransitionEdge) -> Void
    let onSetTransitionCurve: (TransitionEdge, TransitionCurve) -> Void
    let onDetachAudio: () -> Void
    /// Arrow moves and trims, blade splits where clicked, slip changes the
    /// footage a clip plays.
    let tool: TimelineTool
    let snap: (CMTime) -> CMTime
    /// Splits the clip at a timeline time, from the blade.
    let onBlade: (CMTime) -> Void
    /// The clip after slipping by a time (positive plays later footage).
    let resolveSlip: (CMTime) -> TimelineClip?
    let onSlip: (CMTime) -> Void
    /// Hears each slip draft, then nil when the drag ends (with whether the
    /// slip is being committed).
    let onSlipDraft: (TimelineClip?, Bool) -> Void
    /// The snap target near a timeline time, if snapping is on.
    let snapTime: (CMTime) -> CMTime?
    /// Where a moved clip starting at a time and lasting a duration snaps
    /// to, by whichever end is nearer a target, and that target.
    let snapSpan: (CMTime, CMTime) -> (start: CMTime, target: CMTime)?
    let onSnapIndicator: (CMTime?) -> Void
    /// Sets a transition's length, from dragging its inner side.
    let onSetTransitionDuration: (TransitionEdge, CMTime) -> Void

    /// The clip as it will be if the current drag ends now. After a drop
    /// it stays up until the edited clip comes back down from the project:
    /// the edit travels up to the app's state and back through the window,
    /// which can take a display frame longer than this view's own state,
    /// and clearing it at once showed the clip's old place for that frame.
    @State private var preview: TimelineClip?
    /// While moving: the layer the clip will land on, if not its own, and
    /// how far down that layer is.
    @State private var previewTarget: ClipMovePreview?
    /// Counts drops, so a timeout from an earlier one can't clear a later
    /// one's preview; nil when no drop is waiting for its edit.
    @State private var pendingDrop: Int?
    @State private var dropCount = 0
    @State private var isTrimming = false
    /// Whether a move drag is under way.
    @State private var isLifted = false
    @State private var isTransitionTarget = false
    /// Where the blade would cut, in the row's coordinates, while hovering.
    @State private var bladeX: CGFloat?
    /// How far a slip drag in progress moves the footage.
    @State private var slipDelta: CMTime?
    /// A transition's length while its inner side is dragged.
    @State private var transitionDraft: (edge: TransitionEdge, duration: CMTime)?
    /// Counts edits that have come back down from the project, which is
    /// what the block flashes to acknowledge. See `ConfirmFlash`.
    @State private var landedCount = 0
    @Environment(RenderScheduler.self) private var renderer: RenderScheduler?

    private let handleWidth: CGFloat = 8
    private let space = "clipBlock"
    /// How wide a transition must be drawn before its curve can be edited
    /// on the clip; zoom in to get there.
    private let curveEditingWidth: CGFloat = 80

    /// The clip as drawn: the drag preview, with any transition being resized.
    private var shownClip: TimelineClip {
        var shown = preview ?? clip
        if let transitionDraft, var transition = shown.transition(at: transitionDraft.edge) {
            transition.duration = transitionDraft.duration
            shown.setTransition(transition, at: transitionDraft.edge)
        }
        return shown
    }

    var body: some View {
        let shown = shownClip
        let baseX = clip.startOffset.seconds * pixelsPerSecond
        let baseWidth = max(2, clip.trimmedDuration.seconds * pixelsPerSecond)
        let liveX = shown.startOffset.seconds * pixelsPerSecond
        let liveWidth = max(2, shown.trimmedDuration.seconds * pixelsPerSecond)
        let unionMinX = min(baseX, liveX)
        let unionMaxX = max(baseX + baseWidth, liveX + liveWidth)
        // Only the on-screen part of the block is drawn (with a little
        // spare so its clipped ends stay off-screen): zoomed far in, a clip
        // can be millions of points wide, and its name stays in view.
        let drawnMinX = max(liveX, visibleX.lowerBound - 4)
        let drawnMaxX = min(liveX + liveWidth, visibleX.upperBound + 4)
        let drawnX = drawnMaxX > drawnMinX ? drawnMinX : liveX
        let drawnWidth = drawnMaxX > drawnMinX ? drawnMaxX - drawnMinX : liveWidth
        // Only the ends that are really the clip's ends are rounded: a
        // clip zoomed wider than the window is drawn as a slice, and a
        // rounded slice would put a corner in the middle of the clip.
        let shape = blockShape(drawnX: drawnX, drawnWidth: drawnWidth, liveX: liveX, liveWidth: liveWidth)

        ZStack(alignment: .topLeading) {
            if isTrimming {
                // Where the clip was before this trim: an outline, so the
                // distance you have taken off is readable as you drag.
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .fill(typeColor.opacity(0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                            .strokeBorder(typeColor.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                    .frame(width: max(2, unionMaxX - unionMinX), height: height)
                    .offset(x: unionMinX)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Design.Space.tight) {
                    if case .timeline = clip.source {
                        Image(systemName: "rectangle.stack")
                            .font(Design.Typeface.micro)
                    } else if clip.streams == .audio {
                        Image(systemName: "waveform")
                            .font(Design.Typeface.micro)
                    }
                    Text(info?.name ?? "Unknown")
                        .font(Design.Typeface.label)
                        .lineLimit(1)
                }
                .foregroundStyle(Design.textOnColor)
                HStack(spacing: Design.Space.tight) {
                    Text(shown.trimmedDuration.formatted)
                        .font(Design.Typeface.numericMicro)
                    if hasLinkedAudio {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(Design.Typeface.micro)
                            .help("Plays its own sound; show it with the layer's waveform button")
                    }
                }
                .foregroundStyle(Design.textOnColor.opacity(0.7))
            }
            .padding(.leading, drawnX > liveX ? Design.Space.step : Design.Space.close)
            .frame(width: drawnWidth, height: height, alignment: .leading)
            .background(Design.clipFill(typeColor, selected: isSelected))
            .overlay(alignment: .topLeading) {
                transitionMarks(of: shown, liveX: liveX, drawnX: drawnX, drawnWidth: drawnWidth)
            }
            .overlay(alignment: .bottomLeading) {
                if let progress = renderer?.progress(forClip: clip.id) {
                    RenderProgressBar(progress: progress)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    isTransitionTarget ? Design.accent : isSelected ? Design.textOnColor.opacity(0.95) : typeColor.opacity(0.85),
                    lineWidth: isTransitionTarget ? 2 : isSelected ? 1.5 : 1
                )
            }
            // The bevel: lit along the top, shaded along the bottom, so a
            // clip reads as a block sitting in the track rather than as a
            // coloured rectangle painted on it.
            .overlay { shape.strokeBorder(Design.bevelEdgeStrong, lineWidth: 1) }
            // Only the selected clip gets a shadow. A shadow under every
            // block would be both a rasterization pass per clip on a
            // timeline that redraws as you scrub, and the look of a stack
            // of cards rather than of blocks set into a track.
            .shadow(color: .black.opacity(isSelected ? 0.55 : 0), radius: isSelected ? 6 : 0, y: 1)
            .confirmFlash(token: landedCount, color: Design.textOnColor)
            .editorAnimation(Design.Motion.select, value: isSelected)
            .dropDestination(for: TransitionDragPayload.self) { payloads, location in
                guard acceptsTransitions, let payload = payloads.first else { return false }
                // The nearer end of the clip gets the transition.
                let x = drawnX + location.x
                onSetTransition(payload.kind, x - liveX < liveWidth / 2 ? .leading : .trailing)
                onSelect()
                return true
            } isTargeted: { targeted in
                isTransitionTarget = targeted && acceptsTransitions
            }
            .contextMenu { clipMenu }
            .onContinuousHover(coordinateSpace: .named(space)) { phase in
                guard tool == .blade, case .active(let location) = phase else {
                    bladeX = nil
                    return
                }
                let time = bladeTime(atX: location.x)
                bladeX = time > clip.startOffset && time < clip.endOffset ? time.seconds * pixelsPerSecond : nil
            }
            .offset(x: drawnX)
            // Measured in window coordinates: the block moves (and resizes)
            // as the preview changes, so in its own coordinates every
            // one-frame step would shrink the translation by a frame and
            // bounce the preview back to where it was.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard hypot(value.translation.width, value.translation.height) >= 3 else { return }
                        if !isLifted {
                            isLifted = true
                            onDragging(true)
                        }
                        var proposed = CMTimeAdd(clip.startOffset, timeDelta(value.translation.width))
                        let snapped = snapSpan(proposed, clip.trimmedDuration)
                        if let snapped { proposed = snapped.start }
                        onSnapIndicator(snapped?.target)
                        let target = resolveMove(proposed, value.translation.height)
                        var moved = clip
                        moved.startOffset = target?.start ?? clip.startOffset
                        showPreview(moved)
                        previewTarget = target?.layerID == nil ? nil : target
                        onMovePreview(target)
                    }
                    .onEnded { _ in
                        isLifted = false
                        onDragging(false)
                        onSnapIndicator(nil)
                        let targetLayer = previewTarget?.layerID
                        if let preview, preview.startOffset != clip.startOffset || targetLayer != nil {
                            commitDrop { onMove(preview.startOffset, targetLayer) }
                        } else {
                            endDrop()
                        }
                    },
                // Only the arrow moves clips. Off means `.subviews`, not
                // `.none`: `.none` also switches off every gesture already
                // on this view, which let the slip gesture below disable
                // this one and left clips impossible to move.
                including: tool == .arrow ? .all : .subviews
            )
            // With the slip tool, dragging the clip slides its footage under
            // it, like film under a window: right brings earlier frames in.
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { value in
                        let delta = timeDelta(-value.translation.width)
                        let slipped = resolveSlip(delta) ?? clip
                        slipDelta = delta
                        showPreview(slipped)
                        onSlipDraft(slipped, false)
                    }
                    .onEnded { _ in
                        let changed = preview.map { $0 != clip } ?? false
                        onSlipDraft(nil, changed)
                        if changed, let slipDelta {
                            commitDrop { onSlip(slipDelta) }
                        } else {
                            endDrop()
                        }
                        slipDelta = nil
                    },
                including: tool == .slip ? .all : .subviews
            )
            // A click selects the clip, or the transition under it.
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(space)).onEnded { value in
                if tool == .blade {
                    let time = bladeTime(atX: value.location.x)
                    if time > clip.startOffset && time < clip.endOffset { onBlade(time) }
                } else if let edge = transitionEdge(atX: value.location.x, liveX: liveX) {
                    onSelectTransition(edge)
                } else {
                    onSelect()
                }
            })

            // Edge handles are layered on top so grabbing within a few
            // points of either side trims that edge instead of moving the
            // whole clip (SwiftUI resolves overlapping gestures to the
            // topmost hit-testable view at the touch point).
            if tool == .arrow {
                trimHandle(edge: .leading, liveX: liveX, liveWidth: liveWidth)
                trimHandle(edge: .trailing, liveX: liveX, liveWidth: liveWidth)
            }
            if tool == .arrow {
                transitionSideHandles(of: shown, liveX: liveX)
            }
            if tool == .blade, let bladeX {
                Rectangle()
                    .fill(Design.playhead)
                    .frame(width: 1.5, height: height)
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
                    .offset(x: bladeX - 0.75)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height, alignment: .topLeading)
        .offset(y: previewTarget?.offsetY ?? 0)
        .coordinateSpace(.named(space))
        .onChange(of: clip) { _, _ in
            if pendingDrop != nil {
                endDrop()
                // The edit you let go of has arrived: acknowledge it.
                landedCount += 1
            }
        }
    }

    /// The block's outline, rounded only at ends that are really the
    /// clip's ends. See the call site.
    private func blockShape(drawnX: CGFloat, drawnWidth: CGFloat, liveX: CGFloat, liveWidth: CGFloat) -> UnevenRoundedRectangle {
        let radius = Design.Radius.chip
        let startsAtEdge = drawnX <= liveX + 0.5
        let endsAtEdge = drawnX + drawnWidth >= liveX + liveWidth - 0.5
        return UnevenRoundedRectangle(
            topLeadingRadius: startsAtEdge ? radius : 0,
            bottomLeadingRadius: startsAtEdge ? radius : 0,
            bottomTrailingRadius: endsAtEdge ? radius : 0,
            topTrailingRadius: endsAtEdge ? radius : 0,
            style: .continuous
        )
    }

    /// The timeline time the blade cuts at for `x` in the row: on a frame.
    private func bladeTime(atX x: CGFloat) -> CMTime {
        let time = CMTime(seconds: Double(max(0, x) / pixelsPerSecond), preferredTimescale: EditingProject.audioPlacementTimescale)
        return snap(snapTime(time) ?? time)
    }

    /// The end whose transition covers `x` (in the clip's row), if any.
    private func transitionEdge(atX x: CGFloat, liveX: CGFloat) -> TransitionEdge? {
        let durations = clip.effectiveTransitionDurations(lead: joinedLead ?? .zero)
        let end = liveX + clip.trimmedDuration.seconds * pixelsPerSecond
        if clip.transitionIn != nil, joinedLead == nil, x >= liveX, x <= liveX + durations.leading.seconds * pixelsPerSecond {
            return .leading
        }
        if clip.transitionOut != nil, x <= end, x >= end - durations.trailing.seconds * pixelsPerSecond {
            return .trailing
        }
        return nil
    }

    private enum Edge { case leading, trailing }

    @ViewBuilder
    private var clipMenu: some View {
        if let transition = clip.transitionIn {
            Button("Remove \(transition.kind.name) at Start") { onRemoveTransition(.leading) }
        }
        if let transition = clip.transitionOut {
            Button("Remove \(transition.kind.name) at End") { onRemoveTransition(.trailing) }
        }
        if hasLinkedAudio {
            if clip.transitionIn != nil || clip.transitionOut != nil { Divider() }
            Button("Detach Audio", action: onDetachAudio)
        }
    }

    /// Shaded wedges over the part of the clip each transition plays in,
    /// shaped by their curves, in the block's drawn coordinates. A selected
    /// one wide enough on screen shows its curve's points to edit.
    private func transitionMarks(of shown: TimelineClip, liveX: CGFloat, drawnX: CGFloat, drawnWidth: CGFloat) -> some View {
        let durations = shown.effectiveTransitionDurations(lead: joinedLead ?? .zero)
        let liveEnd = liveX + shown.trimmedDuration.seconds * pixelsPerSecond
        let leadingWidth = durations.leading.seconds * pixelsPerSecond
        let trailingWidth = durations.trailing.seconds * pixelsPerSecond
        return ZStack(alignment: .topLeading) {
            if let transition = shown.transitionIn, joinedLead == nil, leadingWidth > 0 {
                transitionMark(transition, edge: .leading, width: leadingWidth)
                    .offset(x: liveX - drawnX)
            }
            if let transition = shown.transitionOut, trailingWidth > 0 {
                transitionMark(transition, edge: .trailing, width: trailingWidth)
                    .offset(x: liveEnd - trailingWidth - drawnX)
            }
        }
        .frame(width: drawnWidth, height: height, alignment: .topLeading)
        .clipped()
    }

    private func transitionMark(_ transition: ClipTransition, edge: TransitionEdge, width: CGFloat) -> some View {
        let isSelected = selectedTransition == edge
        return ZStack(alignment: .topLeading) {
            TransitionMark(kind: transition.kind, curve: transition.curve, edge: edge, isSelected: isSelected)
                .frame(width: width, height: height)
                .contextMenu { transitionMenu(transition, edge: edge) }
            if isSelected, width >= curveEditingWidth, height >= 30 {
                TransitionCurveEditor(
                    curve: transition.curve,
                    edge: edge,
                    size: CGSize(width: width, height: height),
                    onChange: { onSetTransitionCurve(edge, $0) }
                )
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    @ViewBuilder
    private func transitionMenu(_ transition: ClipTransition, edge: TransitionEdge) -> some View {
        let current = transition.curve.preset
        ForEach(TransitionCurve.Preset.allCases) { preset in
            Button {
                onSetTransitionCurve(edge, TransitionCurve(preset: preset))
            } label: {
                if current == preset {
                    Label(preset.name, systemImage: "checkmark")
                } else {
                    Text(preset.name)
                }
            }
            .help(preset.detail)
        }
        Divider()
        Button("Remove \(transition.kind.name)") { onRemoveTransition(edge) }
    }

    /// Sets the preview for a drag in progress.
    private func showPreview(_ clip: TimelineClip) {
        pendingDrop = nil
        preview = clip
    }

    /// Commits a drop and keeps showing the preview until the edited clip
    /// arrives. If it never does (the edit was refused), the preview goes
    /// after a moment.
    private func commitDrop(_ commit: () -> Void) {
        dropCount += 1
        let drop = dropCount
        pendingDrop = drop
        commit()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if pendingDrop == drop { endDrop() }
        }
    }

    private func endDrop() {
        pendingDrop = nil
        preview = nil
        previewTarget = nil
        onMovePreview(nil)
    }

    private func timeDelta(_ translation: CGFloat) -> CMTime {
        CMTime(seconds: Double(translation / pixelsPerSecond), preferredTimescale: EditingProject.audioPlacementTimescale)
    }

    /// The inner side of each transition on the clip's own ends (not one
    /// joining the clip before): dragging it changes the length, the outer
    /// side staying at the clip's end.
    @ViewBuilder
    private func transitionSideHandles(of shown: TimelineClip, liveX: CGFloat) -> some View {
        let durations = shown.effectiveTransitionDurations(lead: joinedLead ?? .zero)
        let liveEnd = liveX + shown.trimmedDuration.seconds * pixelsPerSecond
        if let transition = clip.transitionIn, joinedLead == nil, durations.leading > .zero {
            transitionSideHandle(.leading, transition: transition, atX: liveX + durations.leading.seconds * pixelsPerSecond)
        }
        if let transition = clip.transitionOut, durations.trailing > .zero {
            transitionSideHandle(.trailing, transition: transition, atX: liveEnd - durations.trailing.seconds * pixelsPerSecond)
        }
    }

    private func transitionSideHandle(_ edge: TransitionEdge, transition: ClipTransition, atX x: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6, height: height)
            .contentShape(Rectangle())
            .offset(x: x - 3)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // Inward is longer for a way in, shorter for a way out.
                        let delta = timeDelta(edge == .leading ? value.translation.width : -value.translation.width)
                        let duration = snap(CMTimeAdd(transition.duration, delta))
                        if duration > .zero { transitionDraft = (edge, duration) }
                    }
                    .onEnded { _ in
                        if let transitionDraft { onSetTransitionDuration(edge, transitionDraft.duration) }
                        transitionDraft = nil
                    }
            )
            .pointerStyle(.columnResize)
            .help("Drag to change the transition's length")
    }

    /// A trim drag of `edge` moved by `translation` points: previews it.
    private func trimChanged(_ edge: Edge, translation: CGFloat) {
        isTrimming = true
        var delta = timeDelta(translation)
        let edgeTime = edge == .leading ? clip.startOffset : clip.endOffset
        let snapped = snapTime(CMTimeAdd(edgeTime, delta))
        if let snapped { delta = CMTimeSubtract(snapped, edgeTime) }
        onSnapIndicator(snapped)
        let trimmed = switch edge {
        case .leading: resolveTrimStart(CMTimeAdd(clip.trimStart, delta)) ?? clip
        case .trailing: resolveTrimEnd(CMTimeAdd(clip.trimEnd, delta)) ?? clip
        }
        showPreview(trimmed)
    }

    /// A trim drag ended: commits it, or selects the clip when it was a click.
    private func trimEnded(_ edge: Edge) {
        onSnapIndicator(nil)
        if let preview, preview != clip {
            commitDrop {
                switch edge {
                case .leading: onTrimStart(preview.trimStart)
                case .trailing: onTrimEnd(preview.trimEnd)
                }
            }
        } else {
            if !isTrimming { onSelect() }
            endDrop()
        }
        isTrimming = false
    }

    private func trimHandle(edge: Edge, liveX: CGFloat, liveWidth: CGFloat) -> some View {
        let handleX = edge == .leading ? liveX - handleWidth / 2 : liveX + liveWidth - handleWidth / 2
        return Rectangle()
            .fill(Color.clear)
            .frame(width: handleWidth, height: height)
            .contentShape(Rectangle())
            .offset(x: handleX)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard hypot(value.translation.width, value.translation.height) >= 3 else { return }
                        trimChanged(edge, translation: value.translation.width)
                    }
                    .onEnded { _ in trimEnded(edge) }
            )
            .pointerStyle(.columnResize)
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

/// The area under a transition's curve.
struct TransitionWedge: Shape {
    let curve: TransitionCurve
    let edge: TransitionEdge

    func path(in rect: CGRect) -> Path {
        var path = TransitionCurveFrame(size: rect.size, edge: edge, inset: 0).path(of: curve)
        path.addLine(to: CGPoint(x: edge == .leading ? rect.width : 0, y: rect.height))
        path.closeSubpath()
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The sound of a layer's video clips, shown under the clips when the layer's
/// waveform button is on. Each block sits under the clip it belongs to and
/// moves with it; detaching makes it a clip of its own.
struct LinkedAudioLane: View {
    let layer: TimelineLayer
    let project: EditingProject
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let height: CGFloat
    let visibleX: ClosedRange<CGFloat>
    let onSelectClip: (TimelineClip) -> Void
    let onDetachAudio: (UUID) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layer.clips.filter { project.hasLinkedAudio($0) }) { clip in
                let x = clip.startOffset.seconds * pixelsPerSecond
                let clipWidth = max(2, clip.trimmedDuration.seconds * pixelsPerSecond)
                let drawnMinX = max(x, visibleX.lowerBound - 4)
                let drawnMaxX = min(x + clipWidth, visibleX.upperBound + 4)
                if drawnMaxX > drawnMinX {
                    let tone = Design.ClipTone.audio.color
                    HStack(spacing: Design.Space.tight) {
                        Image(systemName: "waveform")
                        Text("Linked audio")
                            .lineLimit(1)
                    }
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textOnColor.opacity(0.75))
                    .padding(.leading, Design.Space.close)
                    .frame(width: drawnMaxX - drawnMinX, height: height, alignment: .leading)
                    .background(Design.clipFill(tone, selected: false))
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                            .strokeBorder(Design.bevelEdge, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectClip(clip) }
                    .contextMenu {
                        Button("Detach Audio") { onDetachAudio(clip.id) }
                    }
                    .offset(x: drawnMinX)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}
