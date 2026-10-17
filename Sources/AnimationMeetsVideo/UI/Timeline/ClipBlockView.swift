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
    /// How many effects are in the clip's stack, for its badge.
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
    let onCopyEffects: () -> Void
    let onPasteEffects: () -> Void
    let onSetPassThrough: (Bool) -> Void
    /// Whether the clip makes sound, which a retimed clip's sound choice is for.
    let playsSound: Bool
    let onEditTime: ((inout ClipTime) -> Void) -> Void
    let onEditClip: ((inout TimelineClip) -> Void) -> Void
    /// Opens the beat match panel for the clip's song; nil for clips that
    /// aren't on a Music layer.
    var onBeatMatch: (() -> Void)? = nil

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
    /// While moving, how far the block is drawn from where it will land, so
    /// it stays under the pointer; an outline marks the landing place. On
    /// release it goes to zero, and the block settles into its place.
    @State private var carry: CGSize = .zero
    @State private var isDropTarget = false
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
    /// Scrolls the timeline while a move or trim holds the pointer at an edge.
    @Environment(TimelineAutoScroll.self) private var autoScroll: TimelineAutoScroll?

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

            if isLifted {
                // The slot the clip was picked up from. It stays on the
                // clip's own layer while the clip is carried to another.
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .fill(Color.black.opacity(0.22))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                            .strokeBorder(typeColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                    .frame(width: baseWidth, height: height)
                    .offset(x: baseX, y: -(previewTarget?.offsetY ?? 0))
                    .allowsHitTesting(false)

                // Where it will land if let go now: snapped, on a frame and
                // clear of other clips, while the block itself follows the
                // pointer.
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .fill(typeColor.opacity(0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                            .strokeBorder(typeColor, lineWidth: 1.5)
                    }
                    .frame(width: liveWidth, height: height)
                    .offset(x: liveX)
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
                        .layoutPriority(-1)
                    HStack(spacing: Design.Space.tight) {
                        if hasLinkedAudio {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(Design.Typeface.micro)
                                .help("Plays its own sound; show it with the layer's waveform button")
                        }
                        if effectCount > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "wand.and.stars")
                                Text("\(effectCount)").font(Design.Typeface.numericMicro)
                            }
                            .font(Design.Typeface.micro)
                            .help("\(effectCount) effect\(effectCount == 1 ? "" : "s") in its stack")
                        }
                        if hasPasteChanges {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(Design.Typeface.micro)
                                .help("Effects pasted onto this clip have changes to resolve before it can be exported")
                        }
                        if passesThrough {
                            Image(systemName: "square.stack.3d.down.right")
                                .font(Design.Typeface.micro)
                                .help("Passes through: its layers are drawn into the timeline it is placed in")
                        }
                        if !shown.time.isDefault {
                            Image(systemName: "clock")
                                .font(Design.Typeface.micro)
                                .help(shown.isRetimed ? "Retimed: plays at \(NumericExpression.format(shown.speed(atSource: shown.trimStart), maxFractionDigits: 1))%" : "Time settings")
                        }
                        if !shown.shutter.isOff {
                            Image(systemName: "camera.aperture")
                                .font(Design.Typeface.micro)
                                .help("Motion blur or trails")
                        }
                    }
                    // Quieter than the name, but no lower than 90%:
                    // dimmer fails 4.5:1 on the fill (see `clipFill`).
                    .foregroundStyle(Design.textOnColor.opacity(0.9))
                }
                .foregroundStyle(Design.textOnColor)
                // Where a retimed clip's speed is set, along the bar.
                RetimeStrip(
                    marks: RetimeMark.marks(of: shown), pixelsPerSecond: pixelsPerSecond,
                    inset: drawnX - liveX, width: drawnWidth
                )
                // The strip counts from the bar's edge, not the label's.
                .padding(.leading, -(drawnX > liveX ? Design.Space.step : Design.Space.close))
            }
            .padding(.leading, drawnX > liveX ? Design.Space.step : Design.Space.close)
            .frame(width: drawnWidth, height: height, alignment: .leading)
            .background {
                Design.clipFill(typeColor, selected: isSelected)
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
            // Only the selected clip gets a shadow. A shadow under every
            // block would be both a rasterization pass per clip on a
            // timeline that redraws as you scrub, and the look of a stack
            // of cards rather than of blocks set into a track.
            .shadow(color: .black.opacity(isSelected ? 0.55 : 0), radius: isSelected ? 6 : 0, y: 1)
            // Picked up: a little larger, raised, and casting a longer
            // shadow on the track, so it reads as held above the other
            // clips rather than sliding among them.
            .scaleEffect(isLifted ? 1.04 : 1)
            .shadow(color: .black.opacity(isLifted ? 0.5 : 0), radius: isLifted ? 10 : 0, y: isLifted ? 7 : 0)
            .offset(y: isLifted ? -3 : 0)
            .confirmFlash(token: landedCount, color: Design.textOnColor)
            .editorAnimation(Design.Motion.select, value: isSelected)
            .editorAnimation(Design.Motion.select, value: isLifted)
            .dropDestination(for: ClipDropPayload.self) { payloads, location in
                guard let payload = payloads.first else { return false }
                if let transition = payload.transition, acceptsTransitions {
                    // The nearer end of the clip gets the transition.
                    let x = drawnX + location.x
                    onSetTransition(transition.kind, x - liveX < liveWidth / 2 ? .leading : .trailing)
                } else if let effect = payload.effect, acceptsEffects {
                    onAddEffect(effect.kind)
                } else if let preset = payload.preset, acceptsEffects {
                    onApplyPreset(preset.presetID)
                } else {
                    return false
                }
                onSelect()
                return true
            } isTargeted: { targeted in
                // Whether this clip takes what is over it isn't known until
                // the drop, so it lights for any drag it could take.
                isDropTarget = targeted && (acceptsTransitions || acceptsEffects)
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
            .offset(carry)
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
                        autoScroll?.track(pointerX: value.location.x) {
                            previewMove(translation: value.translation, pointer: value.location)
                        }
                    }
                    .onEnded { _ in
                        autoScroll?.end()
                        // From under the pointer into the place it lands.
                        withAnimation(Design.Motion.respecting(Design.Motion.panel)) { carry = .zero }
                        isLifted = false
                        onDragging(false)
                        onSnapIndicator(nil)
                        let targetLayer = previewTarget?.layerID
                        if let kind = previewTarget?.newLayer, let start = previewTarget?.start {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Selects the clip. Its actions move and trim it by a frame.")
        .accessibilityAction { onSelect() }
        .accessibilityActions { accessibilityEditActions }
        .onChange(of: clip) { _, _ in
            if pendingDrop != nil {
                endDrop()
                // The edit you let go of has arrived: acknowledge it.
                landedCount += 1
            }
        }
    }

    // MARK: VoiceOver

    /// What the clip is: its name and kind.
    private var accessibilityName: String {
        let kind = switch info {
        case .timeline: "nested timeline"
        case .adjustment: "adjustment clip"
        case .media(let media) where media.kind == .audio || clip.streams == .audio: "audio clip"
        case .media: "video clip"
        case nil: "missing clip"
        }
        return "\(info?.name ?? "Unknown"), \(kind)"
    }

    /// Where it is and what it carries, read after its name.
    private var accessibilityDescription: String {
        var parts = [
            "starts at \(clip.startOffset.timecode(frameRate: frameRate))",
            "\(clip.placedDuration.timecode(frameRate: frameRate)) long",
        ]
        if let transition = clip.transitionIn { parts.append("\(transition.kind.name) at the start") }
        if let transition = clip.transitionOut { parts.append("\(transition.kind.name) at the end") }
        if hasLinkedAudio { parts.append("with its own sound") }
        return parts.joined(separator: ", ")
    }

    /// Moves and trims a frame at a time, and the clip's menu, for VoiceOver.
    /// They go through the same placement rules as dragging.
    @ViewBuilder
    private var accessibilityEditActions: some View {
        let frame = Timeline.frameDuration(for: frameRate)
        Button("Move one frame earlier") {
            onMove(CMTimeMaximum(.zero, CMTimeSubtract(clip.startOffset, frame)), nil)
        }
        Button("Move one frame later") { onMove(CMTimeAdd(clip.startOffset, frame), nil) }
        Button("Trim start one frame earlier") { onTrimStart(CMTimeSubtract(clip.trimStart, frame)) }
        Button("Trim start one frame later") { onTrimStart(CMTimeAdd(clip.trimStart, frame)) }
        Button("Trim end one frame earlier") { onTrimEnd(CMTimeSubtract(clip.trimEnd, frame)) }
        Button("Trim end one frame later") { onTrimEnd(CMTimeAdd(clip.trimEnd, frame)) }
        if let transition = clip.transitionIn, joinedLead == nil {
            Button("Remove \(transition.kind.name) at start") { onRemoveTransition(.leading) }
        }
        if let transition = clip.transitionOut {
            Button("Remove \(transition.kind.name) at end") { onRemoveTransition(.trailing) }
        }
        if hasLinkedAudio {
            Button("Detach audio", action: onDetachAudio)
        }
        if let onBeatMatch {
            Button("Beat match", action: onBeatMatch)
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
        // The block is drawn at its landing place, moved by this: from
        // there to where the pointer has carried it.
        carry = CGSize(
            width: CMTimeSubtract(clip.startOffset, moved.startOffset).seconds * pixelsPerSecond + across,
            height: translation.height - (previewTarget?.offsetY ?? 0)
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
        let end = liveX + clip.placedDuration.seconds * pixelsPerSecond
        if clip.transitionIn != nil, joinedLead == nil, x >= liveX, x <= liveX + durations.leading.seconds * pixelsPerSecond {
            return .leading
        }
        if clip.transitionOut != nil, x <= end, x >= end - durations.trailing.seconds * pixelsPerSecond {
            return .trailing
        }
        return nil
    }

    private enum Edge { case leading, trailing }

    /// Shaded wedges over the part of the clip each transition plays in,
    /// shaped by their curves, in the block's drawn coordinates. A selected
    /// one wide enough on screen shows its curve's points to edit.
    private func transitionMarks(of shown: TimelineClip, liveX: CGFloat, drawnX: CGFloat, drawnWidth: CGFloat) -> some View {
        let durations = shown.effectiveTransitionDurations(lead: joinedLead ?? .zero)
        let liveEnd = liveX + shown.placedDuration.seconds * pixelsPerSecond
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
        let liveEnd = liveX + shown.placedDuration.seconds * pixelsPerSecond
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
