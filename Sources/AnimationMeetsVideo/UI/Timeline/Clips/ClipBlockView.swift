import CoreMedia
import SwiftUI

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
    /// The timeline's rate: VoiceOver reads times as its timecode, and moves
    /// and trims by its frames.
    let frameRate: Double
    let info: ResolvedClipInfo?
    let typeColor: Color
    /// Shows a sound badge, and offers to detach the sound.
    let hasLinkedAudio: Bool
    /// Draws the clip's sound behind its label when the layer is tall
    /// enough; for clips that are sound alone.
    let showsWaveform: Bool
    /// Draws the waveform's channels apart, at any height.
    let splitsChannels: Bool
    /// Clips with pictures take transitions dropped from the panel.
    let acceptsTransitions: Bool
    /// Set when the clip's way in joins it to the clip before: that
    /// transition is drawn over the cut by the row instead.
    let joinedLead: CMTime?
    let isSelected: Bool
    /// Whether the clip is one of several picked together with a lasso, which
    /// draw as selected and are copied, deleted and nested as one.
    var isInGroup = false
    /// Adds the clip to the clips picked together, or takes it out: the way to
    /// pick several without a lasso.
    let onToggleInGroup: () -> Void
    /// For a nested timeline's clip: goes into the timeline it plays (a
    /// double-click, the menu's Open Timeline).
    var onOpenNested: (() -> Void)?
    /// The transition selected on this clip, which shows its curve's points
    /// when there is room.
    let selectedTransition: TransitionEdge?
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    let visibleX: ClosedRange<CGFloat>
    let resolveMove: (CMTime, CGPoint) -> ClipMovePreview?
    let resolveTrimStart: (CMTime) -> TimelineClip?
    let resolveTrimEnd: (CMTime) -> TimelineClip?
    let onSelect: () -> Void
    let onMove: (CMTime, UUID?) -> Void
    /// Onto a new layer of a kind, starting at a time.
    let onMoveToNewLayer: (LayerKind, CMTime) -> Void
    let onDragging: (Bool) -> Void
    /// Hears where a move drag will land, and nil when it ends.
    let onMovePreview: (ClipMovePreview?) -> Void
    let onTrimStart: (CMTime) -> Void
    let onTrimEnd: (CMTime) -> Void
    /// Hears each trim draft with the edge being dragged, for the viewer
    /// to show the frame there, then nil when the drag ends.
    let onTrimPreview: (TimelineClip?, TrimPreviewFrames) -> Void
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
    /// Clips with pictures take effects dragged from the effects panel.
    let acceptsEffects: Bool
    /// Clips with sound take sound effects.
    var acceptsSoundEffects = false
    /// How many effects are in the clip's stacks, picture and sound, for
    /// its badge.
    let effectCount: Int
    /// Draws the clip's volume as a line across it.
    let showsVolumeLine: Bool
    /// For a nested clip: whether its layers are drawn into the timeline it
    /// is placed in.
    let passesThrough: Bool
    let onAddEffect: (EffectKind) -> Void
    /// Whether an effect of the clip has paste changes left to resolve.
    let hasPasteChanges: Bool
    let onApplyPreset: (String) -> Void
    let onPasteEffects: () -> Void
    let onClipboard: (ClipboardCommand) -> Void
    /// An Option-drag: a copy goes where the drag would have moved the
    /// clip (its start, and the layer if another, or a new layer's kind).
    let onCopy: (CMTime, UUID?, LayerKind?) -> Void
    /// Files from the Finder dropped on the clip go onto its layer there.
    let onDropFiles: ([URL], CMTime) -> Void
    let onSetPassThrough: (Bool) -> Void
    /// Whether the clip makes sound, which a retimed clip's sound choice is for.
    let playsSound: Bool
    let onEditTime: ((inout ClipTime) -> Void) -> Void
    let onEditClip: ((inout TimelineClip) -> Void) -> Void
    /// Opens the beat match panel for the clip's song; nil for clips that
    /// aren't on a Music layer.
    var onBeatMatch: (() -> Void)? = nil
    /// Removes the song's beat map; nil unless the clip's song has one.
    var onRemoveBeats: (() -> Void)? = nil
    /// Ties the clip to the music at the playhead; nil for clips on a Music
    /// layer, which are the music.
    var onAttachToMusic: (() -> Void)? = nil
    /// Ties the frame playing at a timeline time inside the clip to the
    /// music there, from dragging its music point; nil where
    /// `onAttachToMusic` is.
    var onSetMusicPoint: ((CMTime) -> Void)? = nil
    /// For a song: the timeline times the selected clips are tied to it at,
    /// marked on it to show what their music points hold on to.
    var musicMarks: [CMTime] = []
    /// Opens the motion designer on the clip, or on the clips picked with
    /// it; nil for songs and clips that play backwards.
    var onMotionDesign: (() -> Void)? = nil
    /// For an adjustment clip: what it reaches, and the choices.
    var reach: ReachMenu? = nil

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
    /// Picked up by a move drag: drawn raised off the track, with an
    /// outline left where it came from.
    @State private var isLifted = false
    /// Whether Option is held during the move, which copies the clip.
    @State private var isCopying = false
    /// While moving, how far the block is drawn from where it will land, so
    /// it stays under the pointer; an outline marks the landing place. On
    /// release it goes to zero, and the block settles into its place.
    @State private var carry: CGSize = .zero
    /// The block's laid-out frame in window coordinates (the row's, without
    /// the offsets it is drawn at), kept for it to leave from, or arrive
    /// at, when a move changes its layer (`ClipFlights`).
    @State private var frameBox = FrameBox()
    /// How far the block is drawn from its place while it arrives from where
    /// the same clip was let go on another layer.
    @State private var arrival: CGSize = .zero
    @State private var arrivalChecked = false
    @State private var isDropTarget = false
    /// Where the blade would cut, in the row's coordinates, while hovering.
    @State private var bladeX: CGFloat?
    /// How far a slip drag in progress moves the footage.
    @State private var slipDelta: CMTime?
    /// Where the music point is being dragged to, until the edit lands.
    @State var musicPointDraft: CMTime?
    /// A transition's length while its inner side is dragged.
    @State var transitionDraft: (edge: TransitionEdge, duration: CMTime)?
    /// Counts edits that have come back down from the project, which is
    /// what the block flashes to acknowledge. See `ConfirmFlash`.
    @State private var landedCount = 0
    @Environment(RenderScheduler.self) private var renderer: RenderScheduler?
    /// Scrolls the timeline while a move or trim holds the pointer at an edge.
    @Environment(TimelineAutoScroll.self) private var autoScroll: TimelineAutoScroll?

    /// How wide the trim handles are. They are centered on the clip's
    /// edges, so half of each is outside the block, where the timeline must
    /// not take a press for the start of a lasso.
    static let trimHandleWidth: CGFloat = 8
    private let handleWidth = trimHandleWidth
    /// The band along the top of a clip showing pictures that holds its name.
    private static let labelBand: CGFloat = 18
    let space = "clipBlock"
    /// How wide a transition must be drawn before its curve can be edited
    /// on the clip; zoom in to get there.
    let curveEditingWidth: CGFloat = 80

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
        let baseWidth = max(2, clip.placedDuration.seconds * pixelsPerSecond)
        let liveX = shown.startOffset.seconds * pixelsPerSecond
        let liveWidth = max(2, shown.placedDuration.seconds * pixelsPerSecond)
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
        // A video clip on a layer tall enough shows its footage under a band
        // of its colour that holds its name, so the name keeps its contrast.
        let pictures: MediaClip? = {
            guard case .media(let media)? = info, media.kind.hasPictures,
                  height - Self.labelBand >= ClipThumbnails.minimumHeight
            else { return nil }
            return media
        }()

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
            if isLifted, isCopying {
                // Option-dragged: the clip stays where it was, and a copy
                // goes where the drag ends. Held at its own row while the
                // block is drawn over another.
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .fill(typeColor.opacity(0.35))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                            .strokeBorder(typeColor.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                    .frame(width: baseWidth, height: height)
                    .offset(x: baseX, y: -(previewTarget?.offsetY ?? 0))
                    .allowsHitTesting(false)
            }
            if isLifted, previewTarget?.newLayer == nil {
                // Where the clip will start: the drop line, a little taller
                // than the row so it reads past the clips around it.
                InsertionLine(axis: .vertical)
                    .frame(height: height + 6)
                    .offset(x: liveX - 3.5, y: -3)
                    .editorAnimation(Design.Motion.glide, value: liveX)
                    .zIndex(1)
            }

            VStack(alignment: .leading, spacing: 2) {
                ClipLabelRow(
                    name: info?.name ?? "Unknown",
                    isNestedTimeline: { if case .timeline = clip.source { true } else { false } }(),
                    isAudioStream: clip.streams == .audio,
                    hasLinkedAudio: hasLinkedAudio,
                    soundMuted: playsSound && clip.soundMuted,
                    effectCount: effectCount,
                    hasPasteChanges: hasPasteChanges,
                    passesThrough: passesThrough,
                    timeHelp: shown.time.isDefault ? nil
                        : shown.isRetimed ? "Retimed: plays at \(NumericExpression.format(shown.speed(atSource: shown.trimStart), maxFractionDigits: 1))%" : "Time settings",
                    hasShutter: !shown.shutter.isOff
                )
                .equatable()
                // Where a retimed clip's speed is set, along the bar.
                RetimeStrip(
                    marks: RetimeMark.marks(of: shown), pixelsPerSecond: pixelsPerSecond,
                    inset: drawnX - liveX, width: drawnWidth
                )
                // The strip counts from the bar's edge, not the label's.
                .padding(.leading, -(drawnX > liveX ? Design.Space.step : Design.Space.close))
            }
            .padding(.leading, drawnX > liveX ? Design.Space.step : Design.Space.close)
            .padding(.top, pictures == nil ? 0 : 2)
            .frame(width: drawnWidth, height: height, alignment: pictures == nil ? .leading : .topLeading)
            .background {
                Design.clipFill(typeColor, selected: isSelected)
                    .overlay(alignment: .bottomLeading) {
                        if let pictures {
                            ClipThumbnails(
                                clip: shown, media: pictures, pixelsPerSecond: pixelsPerSecond,
                                liveX: liveX, drawnX: drawnX, width: drawnWidth, height: height - Self.labelBand
                            )
                        }
                    }
                    .overlay(alignment: .leading) { waveform(of: shown, drawnX: drawnX, liveX: liveX, width: drawnWidth) }
                    .overlay(alignment: .leading) { volumeLine(of: shown, drawnX: drawnX, liveX: liveX, width: drawnWidth) }
            }
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
                    isDropTarget ? Design.accent : isSelected ? Design.textOnColor.opacity(0.95) : typeColor.opacity(0.85),
                    lineWidth: isDropTarget ? 2 : isSelected ? 1.5 : 1
                )
            }
            // The bevel: lit along the top, shaded along the bottom, so a
            // clip reads as a block sitting in the track rather than as a
            // coloured rectangle painted on it.
            .overlay { shape.strokeBorder(Design.bevelEdgeStrong, lineWidth: 1) }
            // Turned off: still where it is, drawn faded and without colour,
            // since it plays as a gap.
            .saturation(clip.enabled ? 1 : 0)
            .opacity(clip.enabled ? 1 : 0.45)
            // Only the selected clip gets a shadow. A shadow under every
            // block would be both a rasterization pass per clip on a
            // timeline that redraws as you scrub, and the look of a stack
            // of cards rather than of blocks set into a track.
            .shadow(color: .black.opacity(isSelected ? 0.55 : 0), radius: isSelected ? 6 : 0, y: 1)
            // Picked up: raised and casting a longer shadow on the track, at
            // its own size, so where it sits is exactly where it will land.
            .shadow(color: .black.opacity(isLifted ? 0.5 : 0), radius: isLifted ? 10 : 0, y: isLifted ? 7 : 0)
            .offset(y: isLifted ? -3 : 0)
            .confirmFlash(token: landedCount, color: Design.textOnColor)
            .editorAnimation(Design.Motion.select, value: isSelected)
            .editorAnimation(Design.Motion.select, value: isLifted)
            .dropDestination(for: ClipDropPayload.self) { payloads, location in
                guard let payload = payloads.first else { return false }
                let files = payloads.compactMap(\.file)
                if !files.isEmpty {
                    onDropFiles(files, CMTime(seconds: max(0, Double((drawnX + location.x) / pixelsPerSecond)), preferredTimescale: 600))
                    return true
                }
                if let transition = payload.transition, acceptsTransitions {
                    // The nearer end of the clip gets the transition.
                    let x = drawnX + location.x
                    onSetTransition(transition.kind, x - liveX < liveWidth / 2 ? .leading : .trailing)
                } else if let effect = payload.effect, effect.kind.isAudio ? acceptsSoundEffects : acceptsEffects {
                    onAddEffect(effect.kind)
                } else if let preset = payload.preset, acceptsEffects || acceptsSoundEffects {
                    onApplyPreset(preset.presetID)
                } else {
                    return false
                }
                onSelect()
                return true
            } isTargeted: { targeted in
                // Whether this clip takes what is over it isn't known until
                // the drop, so it lights for any drag it could take.
                isDropTarget = targeted && (acceptsTransitions || acceptsEffects || acceptsSoundEffects)
            }
            .contextMenu { ClipMenuHost(block: self, key: menuKey).equatable() }
            .onContinuousHover(coordinateSpace: .named(space)) { phase in
                guard tool == .blade, case .active(let location) = phase else {
                    bladeX = nil
                    return
                }
                let time = bladeTime(atX: location.x)
                bladeX = time > clip.startOffset && time < clip.endOffset ? time.seconds * pixelsPerSecond : nil
            }
            .offset(x: drawnX)
            .offset(carry)
            .offset(arrival)
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
                            autoScroll?.begin()
                        }
                        previewMove(translation: value.translation, pointer: value.location)
                        isCopying = CopyDragCursor.update()
                        autoScroll?.track(pointerX: value.location.x) {
                            previewMove(translation: value.translation, pointer: value.location)
                        }
                        autoScroll?.trackVertically(pointer: value.location) {
                            previewMove(translation: value.translation, pointer: value.location)
                        }
                    }
                    .onEnded { _ in
                        autoScroll?.end()
                        // From under the pointer into the place it lands. Into
                        // another layer it is a new block that arrives, from
                        // where this one was let go (`ClipFlights`).
                        if previewTarget?.layerID != nil || previewTarget?.newLayer != nil {
                            ClipFlights.shared.depart(clip.id, from: drawnStart(liveX: liveX))
                        }
                        withAnimation(Design.Motion.respecting(Design.Motion.glide)) { carry = .zero }
                        isLifted = false
                        onDragging(false)
                        onSnapIndicator(nil)
                        let targetLayer = previewTarget?.layerID
                        let copying = isCopying
                        isCopying = false
                        CopyDragCursor.end()
                        if copying {
                            // The clip itself doesn't change, so there is
                            // no edit of it to wait for.
                            if let kind = previewTarget?.newLayer, let start = previewTarget?.start {
                                onCopy(start, nil, kind)
                            } else if let preview, preview.startOffset != clip.startOffset || targetLayer != nil {
                                onCopy(preview.startOffset, targetLayer, nil)
                            }
                            endDrop()
                        } else if let kind = previewTarget?.newLayer, let start = previewTarget?.start {
                            commitDrop { onMoveToNewLayer(kind, start) }
                        } else if let preview, preview.startOffset != clip.startOffset || targetLayer != nil {
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
            // A double-click on a nested timeline goes into it.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if tool == .arrow { onOpenNested?() }
            })
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
            musicLinkMarks(of: shown)
            if tool == .blade, let bladeX {
                Rectangle()
                    .fill(Design.skim)
                    .frame(width: 1.5, height: height)
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
                    .offset(x: bladeX - 0.75)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height, alignment: .topLeading)
        .offset(y: previewTarget?.offsetY ?? 0)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            frameBox.frame = frame
            // A clip moved here from another layer arrives from where it
            // was let go, as the block that was dragged is gone by now.
            guard !arrivalChecked else { return }
            arrivalChecked = true
            if let from = ClipFlights.shared.arrive(clip.id) {
                let start = clip.startOffset.seconds * pixelsPerSecond
                arrival = CGSize(width: from.x - (frame.minX + start), height: from.y - frame.minY)
                DispatchQueue.main.async {
                    withAnimation(Design.Motion.respecting(Design.Motion.glide)) { arrival = .zero }
                }
            }
        }
        .coordinateSpace(.named(space))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Selects the clip. Its actions move and trim it by a frame.")
        .accessibilityAction { onSelect() }
        .accessibilityActions { accessibilityEditActions }
        .onChange(of: clip.music) { _, _ in musicPointDraft = nil }
        .onChange(of: clip) { _, _ in
            if pendingDrop != nil {
                endDrop()
                // The edit you let go of has arrived: acknowledge it.
                landedCount += 1
            }
        }
    }

    /// The sound of the drawn part of the clip, faded, once the layer is
    /// tall enough to read it.
    @ViewBuilder
    private func waveform(of shown: TimelineClip, drawnX: CGFloat, liveX: CGFloat, width: CGFloat) -> some View {
        if showsWaveform, splitsChannels || ClipWaveform.strength(atHeight: height) > 0,
           case .media(let media) = info, let url = media.url {
            let sourceStart = shown.sourceTime(atTimelineTime: CMTimeAdd(shown.startOffset, CMTime(seconds: Double((drawnX - liveX) / pixelsPerSecond), preferredTimescale: 600)))
            ClipWaveform(
                url: url,
                fileStart: media.fileTime(forSourceTime: sourceStart).seconds,
                // A retimed clip plays more or less of the file for each
                // second of the timeline.
                secondsPerPoint: shown.speed(atSource: shown.trimStart) / 100 / Double(pixelsPerSecond),
                width: width,
                height: height,
                splitsChannels: splitsChannels
            )
        }
    }

    /// The clip's volume as a line across the drawn part of the block, as
    /// on the layer volume lane: mute at the bottom, +6 dB at the top, and
    /// a faint line at 0 dB.
    @ViewBuilder
    private func volumeLine(of shown: TimelineClip, drawnX: CGFloat, liveX: CGFloat, width: CGFloat) -> some View {
        if showsVolumeLine, width > 0 {
            let first = CMTimeAdd(shown.trimStart, CMTime(seconds: Double((drawnX - liveX) / pixelsPerSecond), preferredTimescale: 600))
            let volume = shown.volume
            let pixels = pixelsPerSecond
            Canvas { context, size in
                let unity = VolumeLane.y(ofLevel: 0, height: size.height)
                context.fill(Path(CGRect(x: 0, y: unity, width: size.width, height: 0.5)), with: .color(Design.textOnColor.opacity(0.35)))
                var line = Path()
                var x: CGFloat = 0
                while x <= size.width + 2 {
                    let time = CMTimeAdd(first, CMTime(seconds: Double(x / pixels), preferredTimescale: 600))
                    let point = CGPoint(x: x, y: VolumeLane.y(ofLevel: volume.value(at: time), height: size.height))
                    if line.isEmpty { line.move(to: point) } else { line.addLine(to: point) }
                    x += 2
                }
                context.stroke(line, with: .color(Design.textOnColor.opacity(0.9)), lineWidth: 1.5)
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)
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

    /// Shows where a move drag `translation` long, with the pointer at
    /// `pointer` in window coordinates, would put the clip, and keeps the
    /// block under the pointer. Counts what the timeline has scrolled
    /// under the drag.
    private func previewMove(translation: CGSize, pointer: CGPoint) {
        let across = translation.width + (autoScroll?.scrolled ?? 0)
        var proposed = CMTimeAdd(clip.startOffset, timeDelta(across))
        let snapped = snapSpan(proposed, clip.placedDuration)
        if let snapped { proposed = snapped.start }
        onSnapIndicator(snapped?.target)
        let target = resolveMove(proposed, pointer)
        var moved = clip
        moved.startOffset = target?.start ?? clip.startOffset
        showPreview(moved)
        previewTarget = target?.layerID == nil && target?.newLayer == nil ? nil : target
        onMovePreview(target)
        // The block stays under the pointer, however the landing place
        // snaps or the clips around it make room, and goes there when it
        // is put down; the landing mark shows where that will be.
        carry = CGSize(
            width: CMTimeSubtract(clip.startOffset, moved.startOffset).seconds * pixelsPerSecond + across,
            height: translation.height - (previewTarget?.offsetY ?? 0)
        )
    }

    /// Where the clip's start is drawn, in window coordinates: the block's
    /// frame is the row's, at the row it was laid out in, and the place in
    /// time, the carry and the drop on another layer only move where it is
    /// drawn, so they are added to it.
    private func drawnStart(liveX: CGFloat) -> CGPoint {
        CGPoint(
            x: frameBox.frame.minX + liveX + carry.width,
            y: frameBox.frame.minY + (previewTarget?.offsetY ?? 0) + carry.height
        )
    }

    /// The timeline time the blade cuts at for `x` in the row: on a frame.
    private func bladeTime(atX x: CGFloat) -> CMTime {
        let time = CMTime(seconds: Double(max(0, x) / pixelsPerSecond), preferredTimescale: EditingProject.audioPlacementTimescale)
        return snap(snapTime(time) ?? time)
    }

    private enum Edge { case leading, trailing }

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

    func timeDelta(_ translation: CGFloat) -> CMTime {
        CMTime(seconds: Double(translation / pixelsPerSecond), preferredTimescale: EditingProject.audioPlacementTimescale)
    }

    /// A trim drag of `edge` moved by `translation` points: previews it.
    private func trimChanged(_ edge: Edge, translation: CGFloat) {
        isTrimming = true
        var delta = timeDelta(translation + (autoScroll?.scrolled ?? 0))
        let edgeTime = edge == .leading ? clip.startOffset : clip.endOffset
        let snapped = snapTime(CMTimeAdd(edgeTime, delta))
        if let snapped { delta = CMTimeSubtract(snapped, edgeTime) }
        onSnapIndicator(snapped)
        let trimmed = switch edge {
        // The trim is in the source, which a retimed clip plays at its speed.
        case .leading: resolveTrimStart(clip.sourceTime(atTimelineTime: CMTimeAdd(clip.startOffset, delta))) ?? clip
        case .trailing: resolveTrimEnd(clip.sourceTime(atTimelineTime: CMTimeAdd(clip.endOffset, delta))) ?? clip
        }
        showPreview(trimmed)
        onTrimPreview(trimmed, edge == .leading ? .first : .last)
    }

    /// A trim drag ended: commits it, or selects the clip when it was a click.
    private func trimEnded(_ edge: Edge) {
        onSnapIndicator(nil)
        onTrimPreview(nil, .both)
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
                        if !isTrimming { autoScroll?.begin() }
                        trimChanged(edge, translation: value.translation.width)
                        autoScroll?.track(pointerX: value.location.x) {
                            trimChanged(edge, translation: value.translation.width)
                        }
                    }
                    .onEnded { _ in
                        autoScroll?.end()
                        trimEnded(edge)
                    }
            )
            .pointerStyle(.columnResize)
    }
}
