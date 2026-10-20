import CoreMedia
import SwiftUI

/// Where a clip being dragged will land, and what moves aside for it.
struct ClipMovePreview: Equatable {
    var start: CMTime
    /// Nil when it stays on its own layer.
    var layerID: UUID?
    /// How far the target layer's row is below the clip's own.
    var offsetY: CGFloat
    /// The clips on the target layer moving right to make room, by id.
    var pushed: [UUID: PushedClip] = [:]
    /// Set while the pointer is over the layer names (the clip keeps its
    /// time) or over the empty part of an area (it starts at `start`): the
    /// clip goes onto a new layer of this kind.
    var newLayer: LayerKind?
}

struct LayerClipRow: View {
    @Environment(BeatMatchController.self) private var beatMatch: BeatMatchController?
    /// Scrolls the area while media from the browser is held at its edge.
    @Environment(TimelineAutoScroll.self) private var autoScroll: TimelineAutoScroll?
    let layer: TimelineLayer
    /// The layer's name as the timeline shows it, for VoiceOver.
    let name: String
    let frameRate: Double
    let project: EditingProject
    /// `project.structure` without the timeline's clips, worked out once for
    /// every row: what the row reads beyond its own layer (see `==`).
    let structure: EditingProject
    let timelineID: UUID
    let selection: TimelineSelection?
    /// This layer's clips picked together with a lasso.
    let groupSelected: Set<UUID>
    /// Adds a clip to the clips picked together, or takes it out.
    let onToggleGroup: (UUID) -> Void
    /// Goes into a nested timeline.
    let onOpenTimeline: (UUID) -> Void
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let height: CGFloat
    /// Draws each channel of sound clips' waveforms in a band of its own.
    let showsChannels: Bool
    /// The on-screen part of the row, in its own x coordinates.
    let visibleX: ClosedRange<CGFloat>
    let onSelectClip: (TimelineClip) -> Void
    /// Where a clip dragged with the pointer at a point in window
    /// coordinates, and asked to start at a time, lands.
    let resolveMove: (TimelineClip, CGPoint, CMTime) -> ClipMovePreview?
    /// Moves a clip to a start time, and to another layer when given.
    let onMoveClip: (UUID, UUID?, CMTime) -> Void
    /// Moves a clip onto a new layer of a kind, at the top.
    let onMoveClipToNewLayer: (UUID, LayerKind, CMTime) -> Void
    let onDraggingClip: (Bool) -> Void
    /// Clips on this layer moving aside for a clip being dragged, drawn
    /// where they will go until the move lands.
    let pushed: [UUID: PushedClip]
    /// Hears where a drag in progress will land, and nil when it ends.
    let onMovePreview: (ClipMovePreview?) -> Void
    let onDropScenes: ([MediaDragPayload], CMTime) -> Bool
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
    /// What edges snap to, or nil with snapping off, read as a drag snaps
    /// (not compared in `==`, since it holds where every layer's clips are),
    /// and how close they must come.
    let liveSnap: LiveSnapTargets
    let snapTolerance: CMTime
    /// Where a drag snapped, to draw; nil when it didn't or ended.
    let onSnapIndicator: (CMTime?) -> Void
    let onTrimPreview: (TimelineClip?) -> Void
    /// An edit of the joint at the start of a clip.
    let onApplyJointEdit: (UUID, JointEdit) -> Void
    let onSetTransitionDuration: (UUID, TransitionEdge, CMTime) -> Void
    /// Adds an effect to the end of a clip's stack.
    let onAddEffect: (UUID, EffectKind) -> Void
    /// Puts the preset with this ID on the clip, below its stack.
    let onApplyPreset: (UUID, String) -> Void
    /// Adds the copied clip's (or effect's) effects to the clip, and takes
    /// over the copied clip's time and shutter.
    let onPasteEffects: (UUID) -> Void
    /// Cut, Copy, Paste or Duplicate from a clip's context menu.
    let onClipboard: (UUID, ClipboardCommand) -> Void
    /// A clip Option-dragged: its copy's start, and the layer it goes onto
    /// if another, or the kind of new layer.
    let onCopyClip: (UUID, CMTime, UUID?, LayerKind?) -> Void
    /// Files from the Finder dropped on a clip, and the time they land at.
    let onDropFiles: ([URL], CMTime) -> Void
    /// Sets whether a nested clip passes through.
    let onSetPassThrough: (UUID, Bool) -> Void
    /// Draws each clip's volume as a line across it.
    let showsVolumeLines: Bool
    /// Applies a change to a clip's time settings (see `editTime`), or to
    /// the clip itself.
    let onEditTime: (UUID, (inout ClipTime) -> Void) -> Void
    let onEditClip: (UUID, (inout TimelineClip) -> Void) -> Void
    /// Sets how far down an adjustment clip reaches: to a layer, or every
    /// layer below for nil.
    let onSetReach: (UUID, UUID?) -> Void

    /// While a slip shortens a clip: how far the clips after it move in.
    private struct FollowerShift: Equatable {
        var clipID: UUID
        var after: CMTime
        var shift: CMTime
    }

    @State private var followerShift: FollowerShift?
    /// The clip lifted by a move drag, drawn above its neighbors.
    @State private var liftedClipID: UUID?

    /// Clips moving aside for media dragged from the browser over this
    /// layer. Only the layer under the drag reads where the pointer is, so
    /// the others don't redraw as it moves.
    private var browserPushed: [UUID: PushedClip] {
        let session = MediaDragSession.shared
        guard session.targetLayerID == layer.id else { return [:] }
        return project.pushedByPieces(session.pieces, onLayer: layer.id, in: timelineID, at: session.targetTime)
    }

    private func shiftX(of clip: TimelineClip) -> CGFloat {
        // A push applies only while the clip is still where it was: once
        // the move lands it is already there, and shifting it again would
        // show it twice as far for a frame.
        if let push = pushed[clip.id] ?? browserPushed[clip.id], clip.startOffset == push.from {
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

    /// What opening a nested timeline's clip does; nil for any other clip.
    private func nestedOpener(for clip: TimelineClip) -> (() -> Void)? {
        guard case .timeline(let nestedID) = clip.source else { return nil }
        return { onOpenTimeline(nestedID) }
    }

    /// Music is beat matched; the panel works on the clip's song.
    private func beatMatchAction(for clip: TimelineClip) -> (() -> Void)? {
        guard layer.kind == .music, case .media(let assetID) = clip.source,
              project.mediaClip(id: assetID)?.url != nil, let beatMatch
        else { return nil }
        return { [project] in beatMatch.open(assetID: assetID, in: project) }
    }

    /// An adjustment clip's reach choices: every layer below its layer, or
    /// down to any video layer below. Nil for other clips.
    private func reachMenu(for clip: TimelineClip) -> ReachMenu? {
        guard clip.source == .adjustment, let timeline = project.timeline(id: timelineID) else { return nil }
        return ReachMenu(
            current: clip.reach,
            options: project.reachOptions(below: layer, in: timeline).map { ($0.id, project.displayName(of: $0, in: timeline)) },
            summary: project.reachDescription(of: clip, in: timeline),
            onChoose: { bottom in onSetReach(clip.id, bottom) }
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layer.clips) { clip in
                let isSelected = selection?.layerID == layer.id && selection?.timelineClipID == clip.id
                let isInGroup = groupSelected.contains(clip.id)
                let info = project.resolvedInfo(for: clip.source)
                let joinedLead = project.joinedLead(of: clip, among: layer.clips)
                ClipBlockView(
                    clip: clip,
                    frameRate: frameRate,
                    info: info,
                    typeColor: layer.kind == .music ? Design.ClipTone.music.color : Design.ClipTone.of(info, streams: clip.streams).color,
                    hasLinkedAudio: project.hasLinkedAudio(clip),
                    showsWaveform: project.isAudioOnly(clip),
                    splitsChannels: showsChannels,
                    acceptsTransitions: project.playsVideo(clip),
                    joinedLead: joinedLead,
                    isSelected: isSelected || isInGroup,
                    isInGroup: isInGroup,
                    onToggleInGroup: { onToggleGroup(clip.id) },
                    onOpenNested: nestedOpener(for: clip),
                    selectedTransition: isSelected ? selection?.transitionEdge : nil,
                    pixelsPerSecond: pixelsPerSecond,
                    height: height,
                    visibleX: visibleX,
                    resolveMove: { start, pointer in resolveMove(clip, pointer, start) },
                    resolveTrimStart: { project.resolvedTrimStart(of: clip.id, in: timelineID, layer: layer.id, to: $0) },
                    resolveTrimEnd: { project.resolvedTrimEnd(of: clip.id, in: timelineID, layer: layer.id, to: $0) },
                    onSelect: { onSelectClip(clip) },
                    onMove: { newStart, targetLayerID in onMoveClip(clip.id, targetLayerID, newStart) },
                    onMoveToNewLayer: { kind, start in onMoveClipToNewLayer(clip.id, kind, start) },
                    onDragging: { dragging in
                        liftedClipID = dragging ? clip.id : nil
                        onDraggingClip(dragging)
                    },
                    onMovePreview: onMovePreview,
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
                    snapTime: { liveSnap.targets?.nearest(to: $0, within: snapTolerance, excluding: clip.id) },
                    snapSpan: { start, duration in
                        liveSnap.targets?.snappedStart(start, duration: duration, within: snapTolerance, excluding: clip.id)
                    },
                    onSnapIndicator: onSnapIndicator,
                    onSetTransitionDuration: { edge, duration in onSetTransitionDuration(clip.id, edge, duration) },
                    acceptsEffects: project.hasEffectStack(clip),
                    acceptsSoundEffects: project.playsAudio(clip),
                    effectCount: clip.effects.count + clip.audioEffects.count,
                    showsVolumeLine: showsVolumeLines && project.playsAudio(clip),
                    passesThrough: clip.passThrough,
                    onAddEffect: { kind in onAddEffect(clip.id, kind) },
                    hasPasteChanges: project.hasUnresolvedPasteChanges(clip),
                    onApplyPreset: { onApplyPreset(clip.id, $0) },
                    onPasteEffects: { onPasteEffects(clip.id) },
                    onClipboard: { onClipboard(clip.id, $0) },
                    onCopy: { start, target, kind in onCopyClip(clip.id, start, target, kind) },
                    onDropFiles: onDropFiles,
                    onSetPassThrough: { onSetPassThrough(clip.id, $0) },
                    playsSound: project.playsAudio(clip),
                    onEditTime: { change in onEditTime(clip.id, change) },
                    onEditClip: { change in onEditClip(clip.id, change) },
                    onBeatMatch: beatMatchAction(for: clip),
                    reach: reachMenu(for: clip)
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
        // While media from the browser is over the layer, it is drawn where
        // it would land; dropped, it goes there.
        .overlay(alignment: .topLeading) {
            LayerDropPreview(project: project, timelineID: timelineID, layerID: layer.id, pixelsPerSecond: pixelsPerSecond, height: height)
        }
        .onDrop(of: [.text], delegate: LayerMediaDropDelegate(
            layerID: layer.id,
            pixelsPerSecond: pixelsPerSecond,
            fits: { [project, timelineID, layerID = layer.id] time in
                project.landing(of: MediaDragSession.shared.pieces, onLayer: layerID, in: timelineID, at: time) != nil
            },
            onDrop: onDropScenes,
            onHover: { [autoScroll, kind = layer.kind] in autoScroll?.trackVertically(in: kind) }
        ))
        // VoiceOver goes through the layers, then into each one's clips.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}

extension LayerClipRow: Equatable {
    /// Whether the row would draw and act the same, so it needn't be redrawn
    /// (the timeline marks it `.equatable()`): its own layer is the same, as
    /// are its sizes, selection, tool and snap tolerance, and the project's
    /// structure without the clips (the media, other timelines, the layers'
    /// order, kinds and names). Where other layers' clips are is read as an
    /// action runs (`liveSnap`, `TimelineView.resolveMove`), so moving a
    /// clip, or dragging a value, on another layer changes none of these.
    /// The closures aren't compared; they are made from the same inputs.
    nonisolated static func == (lhs: LayerClipRow, rhs: LayerClipRow) -> Bool {
        MainActor.assumeIsolated {
            lhs.layer == rhs.layer && lhs.name == rhs.name && lhs.frameRate == rhs.frameRate
                && lhs.timelineID == rhs.timelineID && lhs.selection == rhs.selection
                && lhs.groupSelected == rhs.groupSelected
                && lhs.pixelsPerSecond == rhs.pixelsPerSecond && lhs.width == rhs.width && lhs.height == rhs.height
                && lhs.showsChannels == rhs.showsChannels && lhs.visibleX == rhs.visibleX
                && lhs.pushed == rhs.pushed && lhs.tool == rhs.tool
                && lhs.snapTolerance == rhs.snapTolerance
                && lhs.showsVolumeLines == rhs.showsVolumeLines
                && lhs.structure == rhs.structure
        }
    }
}
