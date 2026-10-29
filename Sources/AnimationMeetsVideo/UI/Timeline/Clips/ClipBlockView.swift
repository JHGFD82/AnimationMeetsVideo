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
    /// Counts drops; nil when no drop is waiting for its edit to come back
    /// down from the project.
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
    /// The drag in progress, and what it last sent up, kept where writing
    /// it doesn't redraw the block.
    @State private var drag = ClipDragBook()
    /// The timecodes VoiceOver reads, made again only when they change
    /// (`accessibilityDescription`).
    @State var timecodes = ClipTimecodeCache()
    /// Where the music point is being dragged to, until the edit lands.
    @State var musicPointDraft: CMTime?
    /// A transition's length while its inner side is dragged.
    @State var transitionDraft: (edge: TransitionEdge, duration: CMTime)?
    /// Counts drops the block has flashed for: an edit that has come back
    /// down from the project, or one that was refused. See `ConfirmFlash`.
    @State private var flashCount = 0
    /// Whether the last flash was for a refused edit, which flashes in the
    /// warning colour.
    @State private var flashRefused = false
    @Environment(RenderScheduler.self) private var renderer: RenderScheduler?
    /// Scrolls the timeline while a move or trim holds the pointer at an edge.
    @Environment(TimelineAutoScroll.self) private var autoScroll: TimelineAutoScroll?
    /// The timecode over the pointer while the block, one of its edges or
    /// a mark on it is dragged.
    @Environment(DragTimecodeReadout.self) var readout: DragTimecodeReadout?

    /// How wide the trim handles are. They are centered on the clip's
    /// edges, so half of each is outside the block, where the timeline must
    /// not take a press for the start of a lasso.
    static let trimHandleWidth: CGFloat = 8
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
        // A video or nested clip on a layer tall enough shows its footage
        // under a band of its colour that holds its name, so the name keeps
        // its contrast.
        let pictures: ClipThumbnails.Footage? = {
            guard model.height - Self.labelBand >= ClipThumbnails.minimumHeight else { return nil }
            switch model.info {
            case .media(let media)? where media.kind.hasPictures: return .file(media)
            case .timeline(let timeline)?: return .timeline(timeline.id)
            default: return nil
            }
        }()
        let showsDetail = drawnWidth >= Self.detailWidth
        // Turned off: still where it is, drawn faded and grey, since it
        // plays as a gap. The outline is outside the clip shape, which
        // bounds the wash that greys what is on the block.
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
                                clip: shown, footage: pictures, pixelsPerSecond: model.pixelsPerSecond,
                                liveX: liveX, drawnX: drawnX, width: drawnWidth, height: model.height - Self.labelBand,
                                loads: !isLifted && !isTrimming
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
            // Turned off: what is drawn on the block, pictures, badges and
            // marks, loses its colour, as it plays as a gap (the fill and
            // outline are drawn grey already); white text keeps its
            // lightness, so it stays readable. A saturation blend, there
            // only while the clip is off, rather than a filter on every
            // block; the clip shape bounds it, so no compositing group.
            .overlay {
                if !model.clip.enabled {
                    Rectangle().fill(.gray).blendMode(.saturation)
                        .frame(width: drawnWidth, height: model.height)
                        .allowsHitTesting(false)
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
            // The blade's line follows the pointer. Watched only with the
            // blade out: tracking the pointer over every clip would run on
            // each move across the timeline for nothing.
            .overlay {
                if model.tool == .blade {
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .named(space)) { phase in
                            guard case .active(let location) = phase else {
                                setBladeX(nil)
                                return
                            }
                            let time = bladeTime(atX: location.x)
                            setBladeX(time > model.clip.startOffset && time < model.clip.endOffset ? time.seconds * model.pixelsPerSecond : nil)
                        }
                }
            }
            .opacity(model.clip.enabled ? 1 : 0.45)
            .offset(y: isLifted ? -3 : 0)
            // A refusal flashes even with Reduce Motion on, when the clip
            // goes back without moving: a rim fading is a colour, not a
            // movement, and with the alert sound it is all that says so.
            .confirmFlash(token: flashCount, color: flashRefused ? Design.statusWarning : Design.textOnColor, evenWithReducedMotion: flashRefused)
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
                // the drop, so it lights for any drag it could take, but not
                // while it is the block being dragged.
                let lit = targeted && !isLifted && !isTrimming
                    && (model.transitionsTaken != .none || model.acceptsEffects || model.acceptsSoundEffects)
                if isDropTarget != lit { isDropTarget = lit }
            }
            .contextMenu { ClipMenuHost(block: self, key: menuKey).equatable() }
            // However short the clip, a press within a few points of it
            // lands on it, to select or move it.
            .contentShape(MinimumWidthRectangle(minWidth: Self.minimumHitWidth))
            .pointerStyle(pointerStyle)
            .offset(x: drawnX)
            .offset(carry)
            .offset(arrival)
            // The arrow moves the clip; the slip tool slides its footage
            // under it, like film under a window: right brings earlier
            // frames in. One gesture for both, which only begins past
            // three points, so a click is left to the taps below and
            // doesn't end a drag that never began. Measured in window
            // coordinates: the block moves (and resizes) as the preview
            // changes, so in its own coordinates every one-frame step
            // would shrink the translation by a frame and bounce the
            // preview back to where it was.
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { value in dragChanged(value) }
                    .onEnded { _ in dragEnded(liveX: liveX) },
                including: ClipDragBook.gestureMask(for: model.tool)
            )
            // A double-click on a nested timeline goes into it, except on
            // one of its transitions: the click selected that, and its
            // details stay up, as on any other clip. Other clips don't
            // watch for double-clicks at all.
            .simultaneousGesture(
                SpatialTapGesture(count: 2, coordinateSpace: .named(space)).onEnded { value in
                    guard model.tool == .arrow, transitionEdge(atX: value.location.x, liveX: liveX) == nil else { return }
                    handlers.onOpenNested?()
                },
                including: Self.doubleClickMask(opensNested: offered.openNested)
            )
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
        // The block's frame is wanted once, to arrive from where a move
        // from another layer let go of it, and while it is picked up, to
        // leave from; not as the timeline scrolls, which moves every
        // block's frame on every step. `frameBox` is a box, so recording
        // it redraws nothing.
        .onGeometryChange(for: CGRect.self, of: { [wantsFrame = isLifted || !arrivalChecked] proxy in
            wantsFrame ? proxy.frame(in: .global) : .null
        }) { frame in
            guard frame != .null else { return }
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
        .onChange(of: model.tool) { _, _ in setBladeX(nil) }
        // A block taken away mid-drag (a trim that scrolled it out of the
        // row) never hears its gesture end: let go of what the drag holds.
        .onDisappear {
            guard drag.kind != nil else { return }
            drag.finish()
            autoScroll?.end()
            CopyDragCursor.end()
        }
        .onChange(of: model.clip) { _, _ in
            if pendingDrop != nil {
                endDrop()
                // The edit you let go of has arrived: acknowledge it.
                flash(refused: false)
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
            ClipWaveform(
                url: url,
                fileTimes: Self.waveformFileTimes(of: shown, media: media, pixelsPerSecond: model.pixelsPerSecond, inset: drawnX - liveX, width: width),
                width: width,
                height: model.height,
                splitsChannels: model.splitsChannels,
                // Not read under a drag; it is read once let go.
                loads: !isLifted && !isTrimming
            )
        }
    }

    /// How far apart a clip whose speed changes is anchored to its file.
    nonisolated static let waveformAnchorStep: CGFloat = 16

    /// Which file time each point across the drawn part of `clip` plays,
    /// `inset` points after its start and `width` wide. At one speed it is
    /// a straight line; a clip whose speed changes along it (more than one
    /// retime mark) is anchored where each speed is set and every
    /// `waveformAnchorStep` points between, so its sound is drawn as far
    /// as it plays, not at its first speed throughout.
    nonisolated static func waveformFileTimes(
        of clip: TimelineClip, media: MediaClip, pixelsPerSecond: CGFloat, inset: CGFloat, width: CGFloat
    ) -> WaveformFileTimes {
        func fileSeconds(atX x: CGFloat) -> Double {
            let along = CMTime(seconds: Double((inset + x) / pixelsPerSecond), preferredTimescale: 48_000)
            return media.fileTime(forSourceTime: clip.sourceTime(atTimelineTime: CMTimeAdd(clip.startOffset, along))).seconds
        }
        let marks = RetimeMark.marks(of: clip)
        guard marks.count > 1 else {
            // A retimed clip plays more or less of the file for each second
            // of the timeline.
            let speed = clip.speed(atSource: clip.trimStart) / 100
            return .linear(start: fileSeconds(atX: 0), secondsPerPoint: speed / Double(pixelsPerSecond))
        }
        var xs = Array(stride(from: CGFloat(0), to: width, by: waveformAnchorStep)) + [width]
        xs += marks.map { CGFloat($0.seconds) * pixelsPerSecond - inset }.filter { $0 > 0 && $0 < width }
        return WaveformFileTimes(anchors: xs.map { .init(x: $0, seconds: fileSeconds(atX: $0)) })
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

    /// The narrowest a clip is to a press: a shorter one takes presses a
    /// little either side of it.
    static let minimumHitWidth: CGFloat = 6

    /// How wide each trim handle is on a clip `width` points wide: the
    /// full width while that leaves room between them to grab the clip
    /// and move it, and a quarter of the clip on a narrower one (two
    /// points at least), so its middle still moves it.
    static func trimHandleWidth(forClipWidth width: CGFloat) -> CGFloat {
        width >= 3 * trimHandleWidth ? trimHandleWidth : max(2, width / 4)
    }

    /// Whether the block watches for double-clicks: only a nested
    /// timeline's, which a double-click opens. Off is `.subviews`, never
    /// `.none`, which would switch off the gestures inside the block too.
    static func doubleClickMask(opensNested: Bool) -> GestureMask {
        opensNested ? .all : .subviews
    }

    /// The pointer over the block: an open hand with the arrow, closed
    /// while the clip is carried (but for an Option-drag, which shows the
    /// copy pointer); the resize arrows with the slip tool, which slides
    /// the footage sideways. The trim handles show their own.
    private var pointerStyle: PointerStyle? {
        switch model.tool {
        case .arrow: isLifted ? (isCopying ? nil : .grabActive) : .grabIdle
        case .slip: .columnResize
        case .blade: nil
        }
    }

    private func setBladeX(_ x: CGFloat?) {
        if bladeX != x { bladeX = x }
    }

    // MARK: Dragging

    /// The block's drag moved: begins a move or slip, by the tool, on its
    /// first move, then follows it.
    private func dragChanged(_ value: DragGesture.Value) {
        if drag.kind == nil {
            guard let kind = ClipDragBook.Kind(tool: model.tool) else { return }
            drag.begin(kind) { cancelDrag() }
        }
        guard !drag.isCancelledDrag else { return }
        switch drag.kind {
        case .move: moveChanged(value)
        case .slip: slipChanged(value)
        case .trim, nil: break
        }
    }

    private func dragEnded(liveX: CGFloat) {
        defer { drag.finish() }
        guard !drag.isCancelledDrag else { return }
        switch drag.kind {
        case .move: moveEnded(liveX: liveX)
        case .slip: slipEnded()
        case .trim, nil: break
        }
    }

    /// Escape during a move, trim or slip: the drag is dropped, and the
    /// clip goes back to where it was with nothing edited. The button is
    /// still down; the rest of the drag is ignored.
    private func cancelDrag() {
        drag.cancel()
        drag.slipDelta = nil
        autoScroll?.end()
        CopyDragCursor.end()
        if isCopying { isCopying = false }
        if isLifted {
            isLifted = false
            handlers.onDragging(false)
        }
        if isTrimming { isTrimming = false }
        readout?.hide()
        sendSnapIndicator(nil)
        sendTrimPreview(nil)
        sendSlipDraft(nil, committing: false)
        withAnimation(Design.Motion.respecting(Design.Motion.springBack)) {
            if carry != .zero { carry = .zero }
            endDrop()
        }
    }

    private func moveChanged(_ value: DragGesture.Value) {
        if !isLifted {
            isLifted = true
            handlers.onDragging(true)
            autoScroll?.begin()
        }
        // Shift keeps the clip on its own layer: the pointer is taken to
        // be on the row the drag began on.
        let onOwnLayer = NSEvent.modifierFlags.contains(.shift)
        let pointer = onOwnLayer ? CGPoint(x: value.location.x, y: value.startLocation.y) : value.location
        let translation = onOwnLayer ? CGSize(width: value.translation.width, height: 0) : value.translation
        let preview = { previewMove(translation: translation, pointer: pointer, onOwnLayer: onOwnLayer, shownAt: value.location) }
        preview()
        let copying = CopyDragCursor.update()
        if isCopying != copying { isCopying = copying }
        autoScroll?.track(pointerX: value.location.x) {
            if !drag.isCancelledDrag { preview() }
        }
        if !onOwnLayer {
            autoScroll?.trackVertically(pointer: value.location) {
                if !drag.isCancelledDrag { preview() }
            }
        }
    }

    private func moveEnded(liveX: CGFloat) {
        autoScroll?.end()
        // Already where it lands, except over the new layer place, from
        // where it settles. Into another layer it is a new block that
        // arrives, from where this one was let go (`ClipFlights`).
        if previewTarget?.layerID != nil || previewTarget?.newLayer != nil {
            ClipFlights.shared.depart(model.clip.id, from: drawnStart(liveX: liveX))
        }
        if carry != .zero {
            withAnimation(Design.Motion.respecting(Design.Motion.glide)) { carry = .zero }
        }
        isLifted = false
        handlers.onDragging(false)
        readout?.hide()
        sendSnapIndicator(nil)
        let targetLayer = previewTarget?.layerID
        let copying = isCopying
        if isCopying { isCopying = false }
        CopyDragCursor.end()
        if copying {
            // The clip itself doesn't change, so there is no edit of it to
            // wait for.
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
    }

    private func slipChanged(_ value: DragGesture.Value) {
        let delta = timeDelta(-value.translation.width)
        let slipped = handlers.resolveSlip(delta) ?? model.clip
        drag.slipDelta = delta
        showPreview(slipped)
        sendSlipDraft(slipped, committing: false)
        // How far the footage moved, as the clip's in point shows it.
        readout?.showSlip(CMTimeSubtract(slipped.trimStart, model.clip.trimStart), pointer: value.location)
    }

    private func slipEnded() {
        readout?.hide()
        let changed = preview.map { $0 != model.clip } ?? false
        sendSlipDraft(nil, committing: changed)
        if changed, let slipDelta = drag.slipDelta {
            commitDrop { handlers.onSlip(slipDelta) }
        } else {
            endDrop()
        }
        drag.slipDelta = nil
    }

    /// Shows where a move drag `translation` long, with the pointer at
    /// `pointer` in window coordinates, would put the clip, and keeps the
    /// block under the pointer. Counts what the timeline has scrolled
    /// under the drag. `onOwnLayer`, it doesn't go onto another layer, or
    /// a new one. The timecode it lands at shows over `shownAt`, where the
    /// pointer really is.
    private func previewMove(translation: CGSize, pointer: CGPoint, onOwnLayer: Bool, shownAt: CGPoint) {
        let across = translation.width + (autoScroll?.scrolled ?? 0)
        var proposed = CMTimeAdd(model.clip.startOffset, timeDelta(across))
        let snapped = handlers.snapSpan(proposed, model.clip.placedDuration)
        if let snapped { proposed = snapped.start }
        sendSnapIndicator(snapped?.target)
        var target = handlers.resolveMove(proposed, pointer)
        if onOwnLayer, target?.layerID != nil || target?.newLayer != nil { target = nil }
        var moved = model.clip
        moved.startOffset = target?.start ?? model.clip.startOffset
        showPreview(moved)
        readout?.show(moved.startOffset, from: model.clip.startOffset, pointer: shownAt)
        let elsewhere = target?.layerID == nil && target?.newLayer == nil ? nil : target
        if previewTarget != elsewhere { previewTarget = elsewhere }
        sendMovePreview(target)
        // The block is drawn where it will land, on a frame and on the
        // layer's row, stepping from frame to frame rather than floating
        // with the pointer. Only over the place a new layer would go,
        // which has no row yet, does it follow the pointer up or down.
        let follow = CGSize(width: 0, height: target?.newLayer == nil ? 0 : translation.height - (elsewhere?.offsetY ?? 0))
        if carry != follow { carry = follow }
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
        if pendingDrop != nil { pendingDrop = nil }
        if preview != clip { preview = clip }
    }

    /// Commits a drop. Made, the preview stays up until the edited clip
    /// comes back down from the project (`onChange(of: model.clip)`).
    /// Refused, the clip springs back to where it was at once, flashing
    /// in the warning colour with the alert sound, so it is clear the
    /// edit didn't happen rather than that it was slow.
    private func commitDrop(_ commit: () -> Bool) {
        dropCount += 1
        pendingDrop = dropCount
        guard commit() else {
            withAnimation(Design.Motion.respecting(Design.Motion.springBack)) { endDrop() }
            flash(refused: true)
            NSSound.beep()
            return
        }
    }

    private func flash(refused: Bool) {
        if flashRefused != refused { flashRefused = refused }
        flashCount += 1
    }

    private func endDrop() {
        if pendingDrop != nil { pendingDrop = nil }
        if preview != nil { preview = nil }
        if previewTarget != nil { previewTarget = nil }
        sendMovePreview(nil)
    }

    // What a drag sends up, each only when it changed: these set state the
    // whole timeline reads, and a drag sends on every pointer move.

    private func sendSnapIndicator(_ time: CMTime?) {
        if drag.snap.changes(to: time) { handlers.onSnapIndicator(time) }
    }

    private func sendMovePreview(_ target: ClipMovePreview?) {
        if drag.movePreview.changes(to: target) { handlers.onMovePreview(target) }
    }

    private func sendTrimPreview(_ clip: TimelineClip?, frames: TrimPreviewFrames = .both) {
        if drag.trimPreview.changes(to: clip.map { ClipDragBook.TrimDraft(clip: $0, frames: frames) }) {
            handlers.onTrimPreview(clip, frames)
        }
    }

    private func sendSlipDraft(_ clip: TimelineClip?, committing: Bool) {
        if drag.slipDraft.changes(to: ClipDragBook.SlipDraft(clip: clip, committing: committing)) {
            handlers.onSlipDraft(clip, committing)
        }
    }

    func timeDelta(_ translation: CGFloat) -> CMTime {
        CMTime(seconds: Double(translation / model.pixelsPerSecond), preferredTimescale: EditingProject.audioPlacementTimescale)
    }

    // MARK: Trimming

    /// A trim drag of `edge` moved by `translation` points, the pointer at
    /// `pointer`: previews it.
    private func trimChanged(_ edge: Edge, translation: CGFloat, pointer: CGPoint) {
        if !isTrimming { isTrimming = true }
        var delta = timeDelta(translation + (autoScroll?.scrolled ?? 0))
        let edgeTime = edge == .leading ? model.clip.startOffset : model.clip.endOffset
        let snapped = handlers.snapTime(CMTimeAdd(edgeTime, delta))
        if let snapped { delta = CMTimeSubtract(snapped, edgeTime) }
        sendSnapIndicator(snapped)
        let trimmed = switch edge {
        // The trim is in the source, which a retimed clip plays at its speed.
        case .leading: handlers.resolveTrimStart(model.clip.sourceTime(atTimelineTime: CMTimeAdd(model.clip.startOffset, delta))) ?? model.clip
        case .trailing: handlers.resolveTrimEnd(model.clip.sourceTime(atTimelineTime: CMTimeAdd(model.clip.endOffset, delta))) ?? model.clip
        }
        showPreview(trimmed)
        sendTrimPreview(trimmed, frames: edge == .leading ? .first : .last)
        switch edge {
        case .leading: readout?.show(trimmed.startOffset, from: model.clip.startOffset, pointer: pointer)
        case .trailing: readout?.show(trimmed.endOffset, from: model.clip.endOffset, pointer: pointer)
        }
    }

    /// A trim drag ended: commits it, or selects the clip when it was a click.
    private func trimEnded(_ edge: Edge) {
        readout?.hide()
        sendSnapIndicator(nil)
        sendTrimPreview(nil)
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
        if isTrimming { isTrimming = false }
    }

    private func trimHandle(edge: Edge, liveX: CGFloat, liveWidth: CGFloat) -> some View {
        let width = Self.trimHandleWidth(forClipWidth: liveWidth)
        let handleX = edge == .leading ? liveX - width / 2 : liveX + liveWidth - width / 2
        return Color.clear
            .frame(width: width, height: model.height)
            .contentShape(Rectangle())
            .offset(x: handleX)
            .gesture(
                // From no distance, so a click on a handle still selects
                // the clip (`trimEnded`); a trim begins past three points.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard hypot(value.translation.width, value.translation.height) >= 3 else { return }
                        if drag.kind == nil {
                            drag.begin(.trim) { cancelDrag() }
                            autoScroll?.begin()
                        }
                        guard !drag.isCancelledDrag else { return }
                        trimChanged(edge, translation: value.translation.width, pointer: value.location)
                        autoScroll?.track(pointerX: value.location.x) {
                            if !drag.isCancelledDrag { trimChanged(edge, translation: value.translation.width, pointer: value.location) }
                        }
                    }
                    .onEnded { _ in
                        defer { drag.finish() }
                        guard !drag.isCancelledDrag else { return }
                        autoScroll?.end()
                        trimEnded(edge)
                    }
            )
            .pointerStyle(.columnResize)
    }
}

/// The frame's rectangle, widened about its middle to `minWidth` when it
/// is narrower: the area a press on a very short clip lands in.
private struct MinimumWidthRectangle: Shape {
    let minWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: min(0, (rect.width - minWidth) / 2), dy: 0))
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
