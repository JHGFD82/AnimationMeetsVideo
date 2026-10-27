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
    let model: ClipBlockModel
    /// Read as the block acts, not as it is drawn: see `ClipBlockHandlers`.
    private let live: LiveClipHandlers
    /// Which optional actions there were when this value was made, which
    /// `==` compares; `live` already holds the newest handlers by then.
    private let offered: ClipBlockHandlers.Offered

    init(model: ClipBlockModel, handlers: LiveClipHandlers) {
        self.model = model
        live = handlers
        offered = handlers.current.offered
    }

    var handlers: ClipBlockHandlers { live.current }

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
    /// While moving over the place a new layer would go, how far up or down
    /// the block is drawn from its row, so it stays under the pointer;
    /// anywhere else it is drawn where it will land and this is zero. On
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
    /// Narrower than this on screen, a clip is only its fill and outline:
    /// its name, pictures, sound and marks couldn't be read.
    static let detailWidth: CGFloat = 24
    let space = "clipBlock"
    /// How wide a transition must be drawn before its curve can be edited
    /// on the clip; zoom in to get there.
    let curveEditingWidth: CGFloat = 80

    /// The clip as drawn: the drag preview, with any transition being resized.
    private var shownClip: TimelineClip {
        var shown = preview ?? model.clip
        if let transitionDraft, var transition = shown.transition(at: transitionDraft.edge) {
            transition.duration = transitionDraft.duration
            shown.setTransition(transition, at: transitionDraft.edge)
        }
        return shown
    }

    var body: some View {
        let shown = shownClip
        let baseX = model.clip.startOffset.seconds * model.pixelsPerSecond
        let baseWidth = max(2, model.clip.placedDuration.seconds * model.pixelsPerSecond)
        let liveX = shown.startOffset.seconds * model.pixelsPerSecond
        let liveWidth = max(2, shown.placedDuration.seconds * model.pixelsPerSecond)
        let unionMinX = min(baseX, liveX)
        let unionMaxX = max(baseX + baseWidth, liveX + liveWidth)
        // Only the on-screen part of the block is drawn (with a little
        // spare so its clipped ends stay off-screen): zoomed far in, a clip
        // can be millions of points wide, and its name stays in view.
        let drawnMinX = max(liveX, model.visibleX.lowerBound - 4)
        let drawnMaxX = min(liveX + liveWidth, model.visibleX.upperBound + 4)
        let drawnX = drawnMaxX > drawnMinX ? drawnMinX : liveX
        let drawnWidth = drawnMaxX > drawnMinX ? drawnMaxX - drawnMinX : liveWidth
        // Only the ends that are really the clip's ends are rounded: a
        // clip zoomed wider than the window is drawn as a slice, and a
        // rounded slice would put a corner in the middle of the clip.
        let shape = blockShape(drawnX: drawnX, drawnWidth: drawnWidth, liveX: liveX, liveWidth: liveWidth)
        // A video clip on a layer tall enough shows its footage under a band
        // of its colour that holds its name, so the name keeps its contrast.
        let pictures: MediaClip? = {
            guard case .media(let media)? = model.info, media.kind.hasPictures,
                  model.height - Self.labelBand >= ClipThumbnails.minimumHeight
            else { return nil }
            return media
        }()
        let showsDetail = drawnWidth >= Self.detailWidth
        // Turned off: still where it is, drawn faded and grey, since it
        // plays as a gap.
        let tone = model.clip.enabled ? model.typeColor : model.typeColor.greyed()

        ZStack(alignment: .topLeading) {
            if isTrimming {
                // Where the clip was before this trim: an outline, so the
                // distance you have taken off is readable as you drag.
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .fill(model.typeColor.opacity(0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                            .strokeBorder(model.typeColor.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                    .frame(width: max(2, unionMaxX - unionMinX), height: model.height)
                    .offset(x: unionMinX)
                    .allowsHitTesting(false)
            }
            if isLifted, isCopying {
                // Option-dragged: the clip stays where it was, and a copy
                // goes where the drag ends. Held at its own row while the
                // block is drawn over another.
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .fill(model.typeColor.opacity(0.35))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                            .strokeBorder(model.typeColor.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                    .frame(width: baseWidth, height: model.height)
                    .offset(x: baseX, y: -(previewTarget?.offsetY ?? 0))
                    .allowsHitTesting(false)
            }
            if isLifted, previewTarget?.newLayer == nil {
                // Where the clip will start: the drop line, a little taller
                // than the row so it reads past the clips around it.
                InsertionLine(axis: .vertical)
                    .frame(height: model.height + 6)
                    .offset(x: liveX - 3.5, y: -3)
                    .zIndex(1)
            }

            ZStack(alignment: .topLeading) {
                if showsDetail {
                    label(of: shown, drawnX: drawnX, liveX: liveX, drawnWidth: drawnWidth)
                        .padding(.leading, drawnX > liveX ? Design.Space.step : Design.Space.close)
                        .padding(.top, pictures == nil ? 0 : 2)
                }
            }
            .frame(width: drawnWidth, height: model.height, alignment: pictures == nil ? .leading : .topLeading)
            .background {
                Design.clipFill(model.typeColor, selected: model.isSelected, enabled: model.clip.enabled)
                    .overlay(alignment: .bottomLeading) {
                        if showsDetail, let pictures {
                            ClipThumbnails(
                                clip: shown, media: pictures, pixelsPerSecond: model.pixelsPerSecond,
                                liveX: liveX, drawnX: drawnX, width: drawnWidth, height: model.height - Self.labelBand,
                                enabled: model.clip.enabled
                            )
                        }
                    }
                    .overlay(alignment: .leading) {
                        if showsDetail { waveform(of: shown, drawnX: drawnX, liveX: liveX, width: drawnWidth) }
                    }
                    .overlay(alignment: .leading) {
                        if showsDetail { volumeLine(of: shown, drawnX: drawnX, liveX: liveX, width: drawnWidth) }
                    }
            }
            .overlay(alignment: .topLeading) {
                if showsDetail { transitionMarks(of: shown, liveX: liveX, drawnX: drawnX, drawnWidth: drawnWidth) }
            }
            .overlay(alignment: .bottomLeading) {
                if let renderer {
                    ClipRenderProgressView(cell: renderer.progressCell(forClip: model.clip.id))
                }
            }
            .clipShape(shape)
            // The outline, and the bevel inside it: lit along the top,
            // shaded along the bottom, so a clip reads as a block sitting
            // in the track rather than as a coloured rectangle painted on
            // it. One overlay for both, so one layer.
            .overlay {
                ZStack {
                    shape.strokeBorder(
                        isDropTarget ? Design.accent : model.isSelected ? Design.textOnColor.opacity(0.95) : tone.opacity(0.85),
                        lineWidth: isDropTarget ? 2 : model.isSelected ? 1.5 : 1
                    )
                    shape.strokeBorder(Design.bevelEdgeStrong, lineWidth: 1)
                }
            }
            // Only a selected or picked-up clip casts a shadow, drawn from
            // its outline alone (see `BlockShadow`), behind it: a shadow
            // modifier on the block would draw all of it, pictures and
            // sound included, offscreen to cast one, on every clip,
            // whether it showed or not. Picked up, it is raised and casts
            // a longer one on the track, at its own size, so where it sits
            // is exactly where it will land.
            .background {
                if model.isSelected || isLifted {
                    BlockShadow(shape: shape, lifted: isLifted)
                }
            }
            .opacity(model.clip.enabled ? 1 : 0.45)
            .offset(y: isLifted ? -3 : 0)
            .confirmFlash(token: landedCount, color: Design.textOnColor)
            .editorAnimation(Design.Motion.select, value: model.isSelected)
            .editorAnimation(Design.Motion.select, value: isLifted)
            .dropDestination(for: ClipDropPayload.self) { payloads, location in
                guard let payload = payloads.first else { return false }
                let files = payloads.compactMap(\.file)
                if !files.isEmpty {
                    handlers.onDropFiles(files, CMTime(seconds: max(0, Double((drawnX + location.x) / model.pixelsPerSecond)), preferredTimescale: 600))
                    return true
                }
                if let generator = payload.generator, model.clip.source != .graphic {
                    handlers.onDropGenerator(generator.kind, CMTime(seconds: max(0, Double((drawnX + location.x) / model.pixelsPerSecond)), preferredTimescale: 600))
                    return true
                }
                if let transition = payload.transition, model.transitionsTaken.takes(transition.kind) {
                    // The nearer end of the clip gets the transition.
                    let x = drawnX + location.x
                    handlers.onSetTransition(transition.kind, x - liveX < liveWidth / 2 ? .leading : .trailing)
                } else if let effect = payload.effect, effect.kind.isAudio ? model.acceptsSoundEffects : model.acceptsEffects {
                    handlers.onAddEffect(effect.kind)
                } else if let generator = payload.generator {
                    // Joins a text or shape clip, below what it draws, so
                    // text can follow the path of a shape above it.
                    handlers.onAddEffect(generator.kind)
                } else if let preset = payload.preset, model.acceptsEffects || model.acceptsSoundEffects {
                    handlers.onApplyPreset(preset.presetID)
                } else {
                    return false
                }
                handlers.onSelect()
                return true
            } isTargeted: { targeted in
                // Whether this clip takes what is over it isn't known until
                // the drop, so it lights for any drag it could take.
                isDropTarget = targeted && (model.transitionsTaken != .none || model.acceptsEffects || model.acceptsSoundEffects)
            }
            .contextMenu { ClipMenuHost(block: self, key: menuKey).equatable() }
            .onContinuousHover(coordinateSpace: .named(space)) { phase in
                guard model.tool == .blade, case .active(let location) = phase else {
                    bladeX = nil
                    return
                }
                let time = bladeTime(atX: location.x)
                bladeX = time > model.clip.startOffset && time < model.clip.endOffset ? time.seconds * model.pixelsPerSecond : nil
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
                            handlers.onDragging(true)
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
                        // Already where it lands, except over the new layer
                        // place, from where it settles. Into another layer
                        // it is a new block that arrives, from where this
                        // one was let go (`ClipFlights`).
                        if previewTarget?.layerID != nil || previewTarget?.newLayer != nil {
                            ClipFlights.shared.depart(model.clip.id, from: drawnStart(liveX: liveX))
                        }
                        withAnimation(Design.Motion.respecting(Design.Motion.glide)) { carry = .zero }
                        isLifted = false
                        handlers.onDragging(false)
                        handlers.onSnapIndicator(nil)
                        let targetLayer = previewTarget?.layerID
                        let copying = isCopying
                        isCopying = false
                        CopyDragCursor.end()
                        if copying {
                            // The clip itself doesn't change, so there is
                            // no edit of it to wait for.
                            if let kind = previewTarget?.newLayer, let start = previewTarget?.start {
                                handlers.onCopy(start, nil, kind)
                            } else if let preview, preview.startOffset != model.clip.startOffset || targetLayer != nil {
                                handlers.onCopy(preview.startOffset, targetLayer, nil)
                            }
                            endDrop()
                        } else if let kind = previewTarget?.newLayer, let start = previewTarget?.start {
                            commitDrop { handlers.onMoveToNewLayer(kind, start) }
                        } else if let preview, preview.startOffset != model.clip.startOffset || targetLayer != nil {
                            commitDrop { handlers.onMove(preview.startOffset, targetLayer) }
                        } else {
                            endDrop()
                        }
                    },
                // Only the arrow moves clips. Off means `.subviews`, not
                // `.none`: `.none` also switches off every gesture already
                // on this view, which let the slip gesture below disable
                // this one and left clips impossible to move.
                including: model.tool == .arrow ? .all : .subviews
            )
            // With the slip tool, dragging the clip slides its footage under
            // it, like film under a window: right brings earlier frames in.
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { value in
                        let delta = timeDelta(-value.translation.width)
                        let slipped = handlers.resolveSlip(delta) ?? model.clip
                        slipDelta = delta
                        showPreview(slipped)
                        handlers.onSlipDraft(slipped, false)
                    }
                    .onEnded { _ in
                        let changed = preview.map { $0 != model.clip } ?? false
                        handlers.onSlipDraft(nil, changed)
                        if changed, let slipDelta {
                            commitDrop { handlers.onSlip(slipDelta) }
                        } else {
                            endDrop()
                        }
                        slipDelta = nil
                    },
                including: model.tool == .slip ? .all : .subviews
            )
            // A double-click on a nested timeline goes into it, except on
            // one of its transitions: the click selected that, and its
            // details stay up, as on any other clip.
            .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named(space)).onEnded { value in
                guard model.tool == .arrow, transitionEdge(atX: value.location.x, liveX: liveX) == nil else { return }
                handlers.onOpenNested?()
            })
            // A click selects the clip, or the transition under it.
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(space)).onEnded { value in
                if model.tool == .blade {
                    let time = bladeTime(atX: value.location.x)
                    if time > model.clip.startOffset && time < model.clip.endOffset { handlers.onBlade(time) }
                } else if let edge = transitionEdge(atX: value.location.x, liveX: liveX) {
                    handlers.onSelectTransition(edge)
                } else {
                    handlers.onSelect()
                }
            })

            // Edge handles are layered on top so grabbing within a few
            // points of either side trims that edge instead of moving the
            // whole clip (SwiftUI resolves overlapping gestures to the
            // topmost hit-testable view at the touch point).
            if model.tool == .arrow {
                trimHandle(edge: .leading, liveX: liveX, liveWidth: liveWidth)
                trimHandle(edge: .trailing, liveX: liveX, liveWidth: liveWidth)
            }
            if model.tool == .arrow {
                transitionSideHandles(of: shown, liveX: liveX)
            }
            musicLinkMarks(of: shown)
            if model.tool == .blade, let bladeX {
                Rectangle()
                    .fill(Design.skim)
                    .frame(width: 1.5, height: model.height)
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
                    .offset(x: bladeX - 0.75)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: model.height, alignment: .topLeading)
        .offset(y: previewTarget?.offsetY ?? 0)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            frameBox.frame = frame
            // A clip moved here from another layer arrives from where it
            // was let go, as the block that was dragged is gone by now.
            guard !arrivalChecked else { return }
            arrivalChecked = true
            if let from = ClipFlights.shared.arrive(model.clip.id) {
                let start = model.clip.startOffset.seconds * model.pixelsPerSecond
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
        .accessibilityAddTraits(model.isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Selects the clip. Its actions move and trim it by a frame.")
        .accessibilityAction { handlers.onSelect() }
        .accessibilityActions { accessibilityEditActions }
        .onChange(of: model.clip.music) { _, _ in musicPointDraft = nil }
        .onChange(of: model.clip) { _, _ in
            if pendingDrop != nil {
                endDrop()
                // The edit you let go of has arrived: acknowledge it.
                landedCount += 1
            }
        }
    }

    /// The clip's name and badges, and a retimed clip's speeds along it.
    private func label(of shown: TimelineClip, drawnX: CGFloat, liveX: CGFloat, drawnWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ClipLabelRow(
                name: model.info?.name ?? "Unknown",
                isNestedTimeline: { if case .timeline = model.clip.source { true } else { false } }(),
                isAudioStream: model.clip.streams == .audio,
                hasLinkedAudio: model.hasLinkedAudio,
                soundMuted: model.playsSound && model.clip.soundMuted,
                effectCount: model.effectCount,
                hasPasteChanges: model.hasPasteChanges,
                passesThrough: model.passesThrough,
                timeHelp: shown.time.isDefault ? nil
                    : shown.isRetimed ? "Retimed: plays at \(NumericExpression.format(shown.speed(atSource: shown.trimStart), maxFractionDigits: 1))%" : "Time settings",
                hasShutter: !shown.shutter.isOff
            )
            .equatable()
            // Where a retimed clip's speed is set, along the bar.
            RetimeStrip(
                marks: RetimeMark.marks(of: shown), pixelsPerSecond: model.pixelsPerSecond,
                inset: drawnX - liveX, width: drawnWidth
            )
            // The strip counts from the bar's edge, not the label's.
            .padding(.leading, -(drawnX > liveX ? Design.Space.step : Design.Space.close))
        }
    }

    /// The sound of the drawn part of the clip, faded, once the layer is
    /// tall enough to read it.
    @ViewBuilder
    private func waveform(of shown: TimelineClip, drawnX: CGFloat, liveX: CGFloat, width: CGFloat) -> some View {
        if model.showsWaveform, model.splitsChannels || ClipWaveform.strength(atHeight: model.height) > 0,
           case .media(let media) = model.info, let url = media.url {
            let sourceStart = shown.sourceTime(atTimelineTime: CMTimeAdd(shown.startOffset, CMTime(seconds: Double((drawnX - liveX) / model.pixelsPerSecond), preferredTimescale: 600)))
            ClipWaveform(
                url: url,
                fileStart: media.fileTime(forSourceTime: sourceStart).seconds,
                // A retimed clip plays more or less of the file for each
                // second of the timeline.
                secondsPerPoint: shown.speed(atSource: shown.trimStart) / 100 / Double(model.pixelsPerSecond),
                width: width,
                height: model.height,
                splitsChannels: model.splitsChannels
            )
        }
    }

    /// The clip's volume as a line across the drawn part of the block.
    @ViewBuilder
    private func volumeLine(of shown: TimelineClip, drawnX: CGFloat, liveX: CGFloat, width: CGFloat) -> some View {
        if model.showsVolumeLine, width > 0 {
            VolumeLineView(
                volume: shown.volume,
                firstSeconds: shown.trimStart.seconds + Double((drawnX - liveX) / model.pixelsPerSecond),
                pixelsPerSecond: model.pixelsPerSecond,
                width: width,
                height: model.height
            )
            .equatable()
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
        var proposed = CMTimeAdd(model.clip.startOffset, timeDelta(across))
        let snapped = handlers.snapSpan(proposed, model.clip.placedDuration)
        if let snapped { proposed = snapped.start }
        handlers.onSnapIndicator(snapped?.target)
        let target = handlers.resolveMove(proposed, pointer)
        var moved = model.clip
        moved.startOffset = target?.start ?? model.clip.startOffset
        showPreview(moved)
        previewTarget = target?.layerID == nil && target?.newLayer == nil ? nil : target
        handlers.onMovePreview(target)
        // The block is drawn where it will land, on a frame and on the
        // layer's row, stepping from frame to frame rather than floating
        // with the pointer. Only over the place a new layer would go,
        // which has no row yet, does it follow the pointer up or down.
        carry = CGSize(
            width: 0,
            height: target?.newLayer == nil ? 0 : translation.height - (previewTarget?.offsetY ?? 0)
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
        let time = CMTime(seconds: Double(max(0, x) / model.pixelsPerSecond), preferredTimescale: EditingProject.audioPlacementTimescale)
        return handlers.snap(handlers.snapTime(time) ?? time)
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
        handlers.onMovePreview(nil)
    }

    func timeDelta(_ translation: CGFloat) -> CMTime {
        CMTime(seconds: Double(translation / model.pixelsPerSecond), preferredTimescale: EditingProject.audioPlacementTimescale)
    }

    /// A trim drag of `edge` moved by `translation` points: previews it.
    private func trimChanged(_ edge: Edge, translation: CGFloat) {
        isTrimming = true
        var delta = timeDelta(translation + (autoScroll?.scrolled ?? 0))
        let edgeTime = edge == .leading ? model.clip.startOffset : model.clip.endOffset
        let snapped = handlers.snapTime(CMTimeAdd(edgeTime, delta))
        if let snapped { delta = CMTimeSubtract(snapped, edgeTime) }
        handlers.onSnapIndicator(snapped)
        let trimmed = switch edge {
        // The trim is in the source, which a retimed clip plays at its speed.
        case .leading: handlers.resolveTrimStart(model.clip.sourceTime(atTimelineTime: CMTimeAdd(model.clip.startOffset, delta))) ?? model.clip
        case .trailing: handlers.resolveTrimEnd(model.clip.sourceTime(atTimelineTime: CMTimeAdd(model.clip.endOffset, delta))) ?? model.clip
        }
        showPreview(trimmed)
        handlers.onTrimPreview(trimmed, edge == .leading ? .first : .last)
    }

    /// A trim drag ended: commits it, or selects the clip when it was a click.
    private func trimEnded(_ edge: Edge) {
        handlers.onSnapIndicator(nil)
        handlers.onTrimPreview(nil, .both)
        if let preview, preview != model.clip {
            commitDrop {
                switch edge {
                case .leading: handlers.onTrimStart(preview.trimStart)
                case .trailing: handlers.onTrimEnd(preview.trimEnd)
                }
            }
        } else {
            if !isTrimming { handlers.onSelect() }
            endDrop()
        }
        isTrimming = false
    }

    private func trimHandle(edge: Edge, liveX: CGFloat, liveWidth: CGFloat) -> some View {
        let handleX = edge == .leading ? liveX - handleWidth / 2 : liveX + liveWidth - handleWidth / 2
        return Rectangle()
            .fill(Color.clear)
            .frame(width: handleWidth, height: model.height)
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

extension ClipBlockView: Equatable {
    /// Whether the block would draw the same, so its row can skip drawing
    /// it again (the row marks it `.equatable()`): the same model, the same
    /// optional actions offered, the same handler box. The handlers
    /// themselves aren't compared; the box holds the row's newest ones,
    /// which the gestures of a block not drawn again read as they run.
    nonisolated static func == (lhs: ClipBlockView, rhs: ClipBlockView) -> Bool {
        MainActor.assumeIsolated {
            lhs.live === rhs.live && lhs.offered == rhs.offered && lhs.model == rhs.model
        }
    }
}

/// The shadow a selected or picked-up block casts on the track, outside
/// it only: cast by a solid copy of its outline whose inside is then
/// cleared, so the block's own translucent fill isn't darkened from below.
/// It composites two shapes, where a shadow on the block would draw the
/// whole block, its pictures and sound included, to cast one.
private struct BlockShadow<S: Shape>: View {
    let shape: S
    let lifted: Bool

    var body: some View {
        ZStack {
            shape.fill(.black.opacity(0.75))
                .shadow(color: .black.opacity(lifted ? 0.5 : 0.55), radius: lifted ? 10 : 6, y: lifted ? 7 : 1)
            shape.fill(.black).blendMode(.destinationOut)
        }
        .compositingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
