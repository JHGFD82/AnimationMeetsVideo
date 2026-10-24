import CoreMedia
import SwiftUI

/// The effects of the selected clip, to the right of the viewer where the
/// inspector goes, and replacing it while open: the clip's stack, framed by the rows that are pinned in place. Each control
/// has a lane of keyframes beside it, on a ruler and playhead that span the
/// clip; a button in the title hides the lanes, leaving the controls the
/// panel's whole width.
struct EffectsPanel: View {
    @Binding var project: EditingProject
    let timelineID: UUID
    let selection: TimelineSelection?
    /// Where the playhead is parked. Not read as this body is built, so a
    /// step of it redraws only what shows it: the animated rows, the lane
    /// line, an EQ graph and the thumbnails' request (`playheadTime` is for
    /// actions).
    let playhead: PlayheadState
    let state: EffectsPanelState
    let onSeek: (CMTime) -> Void
    let onSelectTransition: (TransitionEdge) -> Void
    /// The player, which the playhead line follows while it plays; the
    /// rest of the panel stays at the parked playhead, so playing redraws
    /// only the line. Nil leaves the line parked.
    var playback: PlaybackModel?

    init(
        project: Binding<EditingProject>, timelineID: UUID, selection: TimelineSelection?, playhead: PlayheadState,
        state: EffectsPanelState, onSeek: @escaping (CMTime) -> Void, onSelectTransition: @escaping (TransitionEdge) -> Void,
        playback: PlaybackModel? = nil
    ) {
        _project = project
        self.timelineID = timelineID
        self.selection = selection
        self.playhead = playhead
        self.state = state
        self.onSeek = onSeek
        self.onSelectTransition = onSelectTransition
        self.playback = playback
    }

    /// A panel with the playhead parked at `playheadTime`.
    init(
        project: Binding<EditingProject>, timelineID: UUID, selection: TimelineSelection?, playheadTime: CMTime,
        state: EffectsPanelState, onSeek: @escaping (CMTime) -> Void, onSelectTransition: @escaping (TransitionEdge) -> Void,
        playback: PlaybackModel? = nil
    ) {
        self.init(
            project: project, timelineID: timelineID, selection: selection, playhead: PlayheadState(time: playheadTime),
            state: state, onSeek: onSeek, onSelectTransition: onSelectTransition, playback: playback
        )
    }

    var playheadTime: CMTime { playhead.time }

    /// The project's state, read for a linked row's other axis during a
    /// drag held to one side of it (see `heldControl`).
    @Environment(ProjectState.self) private var projectState: ProjectState?
    /// The surface's graph editor panels.
    @Environment(KeyframeGraphHUDs.self) var graphs: KeyframeGraphHUDs?
    /// Whether each row shows its keyframe lane, with the ruler and
    /// playhead over them. Kept between launches.
    @AppStorage(Preferences.effectsPanelShowsKeyframeLanes) var showsKeyframeLanes = true
    @State private var renamingEffectID: UUID?
    /// The clip whose speed was last refused for crossing zero, until its
    /// speed is next edited.
    @State var speedBlockedClipID: UUID?
    /// Effects being saved as a preset (nil for the whole stack), while the
    /// name is asked for.
    @State private var presetSave: PresetSave?
    /// Where the stack's rows are, for drops on it, and the line showing
    /// where a drag over it would go.
    @State private var stackLayout = EffectStackLayout()
    @State private var stackScroller = EdgeAutoScroll()
    /// The control column's width and the lanes' zoom and scroll.
    @State private var lanes = LaneViewport()
    @State private var dropLine: CGFloat?
    /// The editor's active panel, which has the keys. Read as a key comes
    /// in, not while drawing, so becoming active doesn't redraw the stack.
    @Environment(ActivePanel.self) private var activePanel: ActivePanel?
    @State private var presetName = ""
    @State private var presetError: String?
    /// The clip after each of its effects, at the playhead.
    @State private var thumbnails: [UUID: CGImage] = [:]
    /// The EQ shown larger in a sheet.
    @State private var expandedEqualizer: ExpandedEqualizer?

    private struct ExpandedEqualizer: Identifiable {
        var clipID: UUID
        var effectID: UUID
        var id: UUID { effectID }
    }

    /// What a Save as Preset is saving.
    private struct PresetSave: Identifiable {
        let id = UUID()
        var clipID: UUID
        var effectIDs: Set<UUID>?
        var suggestedName: String
    }

    var timeline: Timeline? { project.timeline(id: timelineID) }

    private var selectedClip: TimelineClip? {
        guard let selection, selection.timelineID == timelineID else { return nil }
        return project.clipAndLayer(selection.timelineClipID, in: timelineID)?.clip
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Effects")
                    .font(Design.Typeface.panelTitle)
                    .foregroundStyle(Design.textPrimary)
                if let clip = selectedClip {
                    Text(project.clipName(clip.id, in: timelineID))
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Toggle(isOn: $showsKeyframeLanes) { Image(systemName: "timeline.selection") }
                    .toggleStyle(.icon)
                    .help(showsKeyframeLanes ? "Hide the keyframe timeline" : "Show the keyframe timeline")
                    .accessibilityLabel("Keyframe timeline")
                    .accessibilityValue(showsKeyframeLanes ? "Shown" : "Hidden")
            }
            .padding(.horizontal, Design.Space.group)
            .padding(.vertical, Design.Space.step)
            .rail(.raised)

            if let clip = selectedClip, let timeline {
                stack(of: clip, in: timeline)
            } else {
                ContentUnavailableView(
                    "No clip selected",
                    systemImage: "square.dashed",
                    description: Text("Select a clip on the timeline to see its effects.")
                )
                .frame(maxHeight: .infinity)
                .sunken(.sunken)
            }
        }
        .panelSurface(.base)
        .background(KeyPressMonitor(handler: handleKey))
        .focusedSceneValue(\.effectsEditActions, editActions)
        .alert("Save as Preset", isPresented: $presetSave.isPresent) {
            TextField("Name", text: $presetName)
            Button("Save", action: savePreset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Presets are shared by every project and appear in the browser.")
        }
        .messageAlert("The Preset Wasn't Saved", message: $presetError)
        .sheet(item: $expandedEqualizer) { item in
            expandedEqualizerSheet(item)
        }
        .onChange(of: selection) { _, _ in
            state.clear()
            renamingEffectID = nil
        }
        // Refreshed when the playhead stops, or the stack changes.
        .background { ThumbnailLoader(playhead: playhead, request: thumbnailRequest(at:), load: loadThumbnails) }
    }

    /// Asks for the thumbnails when the playhead moves, which this body
    /// doesn't follow.
    private struct ThumbnailLoader: View {
        let playhead: PlayheadState
        let request: (CMTime) -> ThumbnailRequest?
        let load: (ThumbnailRequest?) async -> Void

        var body: some View {
            let current = request(playhead.time)
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .task(id: current) { await load(current) }
        }
    }

    private func loadThumbnails(_ request: ThumbnailRequest?) async {
        guard let request else {
            thumbnails = [:]
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let snapshot = project
        let images = await EffectThumbnails.render(
            project: snapshot, timelineID: timelineID, clipID: request.clipID, at: request.time
        )
        guard !Task.isCancelled else { return }
        thumbnails = images
    }

    /// What the thumbnails are drawn from; they are drawn again when it
    /// changes.
    private struct ThumbnailRequest: Equatable {
        var clipID: UUID
        var effects: [Effect]
        var anchorPoint: AnimatedValue<Vector2>
        var time: CMTime
    }

    private func thumbnailRequest(at time: CMTime) -> ThumbnailRequest? {
        guard let clip = selectedClip, let timeline, project.hasEffectStack(clip), !clip.effects.isEmpty else { return nil }
        return ThumbnailRequest(clipID: clip.id, effects: clip.effects, anchorPoint: clip.anchorPoint, time: timeline.snappedToFrame(time))
    }

    // MARK: Stack

    private func stack(of clip: TimelineClip, in timeline: Timeline) -> some View {
        GeometryReader { proxy in
            let laneWidth = max(80, proxy.size.width - lanes.labelWidth - 2 * EffectsPanelMetrics.laneInset)
            let geometry = ClipLaneGeometry(clip: clip, timeline: timeline, width: laneWidth * lanes.zoom)
            // One frame at its widest is as close as the lanes zoom.
            let fitPixelsPerSecond = laneWidth / CGFloat(geometry.duration)
            let maxZoom = CGFloat(max(timeline.frameRate, 1)) * TimelineViewport.maximumFrameWidth / fitPixelsPerSecond
            let layer = project.clipAndLayer(clip.id, in: timelineID)?.layer
            let context = RowContext(
                clip: clip, timeline: timeline, layer: layer ?? TimelineLayer(clips: []),
                geometry: geometry, playhead: playhead
            )

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Stack")
                        .font(Design.Typeface.micro)
                        .foregroundStyle(Design.textTertiary)
                        .padding(.leading, 8)
                        .frame(width: lanes.labelWidth, alignment: .leading)
                    if showsKeyframeLanes {
                        LaneWindow {
                            PanelRuler(geometry: geometry, onSeek: onSeek)
                                .overlay(alignment: .topLeading) { rangeBar(clip, geometry: geometry) }
                        }
                        .padding(.horizontal, EffectsPanelMetrics.laneInset)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Effect lanes ruler")
                        .accessibilityValue("Playhead \(timeline.snappedToFrame(playhead.time).compactTimecode(frameRate: timeline.frameRate)), zoom \(Int((lanes.zoom * 100).rounded())) percent")
                        .accessibilityAdjustableAction { direction in
                            let step = Timeline.frameDuration(for: timeline.frameRate)
                            let now = timeline.snappedToFrame(playhead.time)
                            onSeek(direction == .increment ? CMTimeAdd(now, step) : CMTimeSubtract(now, step))
                        }
                        .accessibilityAction(named: "Zoom the lanes in") { lanes.zoomStep(in: true) }
                        .accessibilityAction(named: "Zoom the lanes out") { lanes.zoomStep(in: false) }
                        .accessibilityAction(named: "Scroll the lanes later") { lanes.scrollStep(later: true) }
                        .accessibilityAction(named: "Scroll the lanes earlier") { lanes.scrollStep(later: false) }
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: PanelRuler.height)
                .background(Design.Surface.raised.color)

                ScrollView {
                    rows(context)
                        .overlay(alignment: .topLeading) { if showsKeyframeLanes { playheadLine(context) } }
                        .overlay(alignment: .topLeading) {
                            if let dropLine {
                                InsertionLine().offset(y: dropLine - 3.5)
                            }
                        }
                        .coordinateSpace(.named(EffectStackLayout.space))
                        .edgeAutoScroll(stackScroller)
                        .onDrop(of: [.url], delegate: EffectStackDropDelegate(
                            clip: clip, layout: stackLayout, scroller: stackScroller,
                            onMark: { line in if line != dropLine { dropLine = line } },
                            onDrop: { target, payload, copy in dropOnStack(target, payload, copy: copy) }
                        ))
                }
                .sunken(.sunken)
            }
            .environment(lanes)
            .onPreferenceChange(ControlColumnWidthKey.self) { width in
                lanes.labelWidth = max(lanes.labelWidth, width.rounded(.up))
            }
            .onChange(of: laneWidth, initial: true) { _, width in lanes.fit(width: width, maxZoom: maxZoom) }
            .onChange(of: maxZoom) { _, zoom in lanes.fit(width: laneWidth, maxZoom: zoom) }
            .onChange(of: clip.id) { _, _ in lanes.reset() }
            .background(alignment: .topLeading) { laneInput(width: laneWidth) }
            .rubberBandSettling(Bindable(lanes).zoomBand)
            .rubberBandSettling(Bindable(lanes).scrollBand)
        }
    }

    /// Pinch, Option-scroll and sideways scroll over the lanes zoom and
    /// scroll them; vertical scrolling still goes to the stack.
    @ViewBuilder
    private func laneInput(width: CGFloat) -> some View {
        if showsKeyframeLanes {
            TimelineInputMonitor(
                onMagnify: { factor, _, x, _ in lanes.zoom(by: factor, aboutX: x, pinching: true) },
                onScroll: { deltaX, deltaY, flags, x, phase in
                    if flags.contains(.option) {
                        lanes.zoom(by: exp(deltaY * 0.01), aboutX: x, pinching: false)
                        return true
                    }
                    // Also without movement, so a lift lets go of the edge.
                    lanes.scroll(by: deltaX, phase: phase)
                    return false
                },
                onMagnifyEnded: { lanes.endPinch() }
            )
            .frame(width: width)
            .padding(.leading, lanes.labelWidth + EffectsPanelMetrics.laneInset)
        }
    }

    /// The selected Keyframing effect's range, over the ruler.
    @ViewBuilder
    private func rangeBar(_ clip: TimelineClip, geometry: ClipLaneGeometry) -> some View {
        if let id = state.selectedEffectID, let effect = clip.effect(id: id), let setup = effect.keyframing {
            KeyframingRangeBar(geometry: geometry, range: setup.range) { start, end in
                editEffect(effect.id, in: clip) { $0.keyframing?.setRange(start: start, end: end, in: clip) }
            }
        }
    }

    /// Everything the rows of the stack need to know about the clip and
    /// the moment.
    @MainActor
    struct RowContext {
        let clip: TimelineClip
        let timeline: Timeline
        /// The layer the clip is on.
        let layer: TimelineLayer
        let geometry: ClipLaneGeometry
        let playhead: PlayheadState

        /// The playhead on a frame, in the timeline's time, for a row that
        /// shows a value that is `animated`. Another row ignores it, and
        /// doesn't read it, or it would be redrawn with every step.
        func frameTime(animated: Bool) -> CMTime {
            animated ? timeline.snappedToFrame(playhead.time) : .zero
        }

        /// The clip's source time at the playhead, held inside the clip, on
        /// the same terms.
        func sourceNow(animated: Bool) -> CMTime {
            animated ? geometry.clampedSource(atTimeline: frameTime(animated: true)) : .zero
        }

        /// The playhead as a row acts, read then rather than when it was
        /// drawn: the rows in a `StackRow` aren't redrawn as it moves.
        var now: (frameTime: CMTime, sourceNow: CMTime) {
            let frame = timeline.snappedToFrame(playhead.actionTime)
            return (frame, geometry.clampedSource(atTimeline: frame))
        }
    }

    @ViewBuilder
    private func rows(_ c: RowContext) -> some View {
        let clip = c.clip
        VStack(spacing: 0) {
            if case .timeline = clip.source {
                labelled(
                    PinnedRow(title: "Pass Through", systemImage: "square.stack.3d.down.right") {
                        Toggle("", isOn: Binding(
                            get: { clip.passThrough },
                            set: { value in project.editClip(clip.id, in: timelineID) { $0.passThrough = value } }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    .help("Draw this timeline's layers straight into the timeline it is placed in, instead of as one picture"),
                    lane: emptyLane(c)
                )
            }
            clipRows(c) { timeRows(c) }
            if project.hasEffectStack(clip) {
                clipRows(c) { anchorRow(c) }
                ForEach(clip.effects) { effect in
                    effectRows(effect, c)
                }
                ForEach([TransitionEdge.leading, .trailing], id: \.self) { edge in
                    if let transition = clip.transition(at: edge) {
                        let note = project.note(for: transition, of: clip)
                        labelled(
                            PinnedRow(
                                title: "\(edge == .leading ? "Start" : "End") · \(transition.kind.name)",
                                systemImage: transition.kind.systemImage,
                                isSelected: selection?.transitionEdge == edge,
                                onSelect: { onSelectTransition(edge) }
                            ) { EmptyView() }
                            .opacity(note?.dims == true ? 0.5 : 1),
                            lane: emptyLane(c)
                        )
                        if let note {
                            besideLane(EffectNoteRow(note: note))
                        }
                    }
                }
            }
            clipRows(c) { shutterRows(c) }
            if project.playsAudio(clip) {
                // Sound comes after pictures: its effects, then its volume
                // and pan, in the order it is played through them.
                ForEach(clip.audioEffects) { effect in
                    effectRows(effect, c)
                }
                clipRows(c) { audioRow(.volume, c) }
                clipRows(c) { audioRow(.pan, c) }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 0, alignment: .top)
    }

    func labelled<Label: View, Lane: View>(_ label: Label, lane: Lane) -> some View {
        HStack(spacing: 0) {
            if showsKeyframeLanes {
                ControlColumn { label }
                LaneWindow { lane }
                    .padding(.horizontal, EffectsPanelMetrics.laneInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.12))
            } else {
                label.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: EffectsPanelMetrics.rowHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Design.hairline).frame(height: 0.5) }
    }

    /// A row with nothing in the lane, such as a note: in the label column
    /// beside an empty lane, or the whole width with the lanes hidden.
    func besideLane<Content: View>(_ content: Content) -> some View {
        HStack(spacing: 0) {
            if showsKeyframeLanes {
                ControlColumn { content }
                Color.black.opacity(0.12)
            } else {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func emptyLane(_ c: RowContext) -> some View {
        Color.clear.frame(width: c.geometry.width)
    }

    private func playheadLine(_ c: RowContext) -> some View {
        PlayheadReader(playhead: playhead) { _ in
            HStack(spacing: 0) {
                ControlColumn { Color.clear.frame(height: 0) }
                LaneWindow {
                    LanePlayheadLine(playback: playback, parked: c.frameTime(animated: true), geometry: c.geometry)
                        .frame(width: c.geometry.width, alignment: .topLeading)
                }
                .padding(.horizontal, EffectsPanelMetrics.laneInset)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Anchor point

    private func anchorRow(_ c: RowContext) -> some View {
        let clip = c.clip
        let animated = clip.anchorPoint.isAnimated
        let value = clip.anchorPoint.value(at: c.sourceNow(animated: animated))
        let key = ParameterKey(timelineID: timelineID, parameter: .anchorPoint(clipID: clip.id))
        return labelled(
            ParameterRow(
                name: "Anchor",
                components: [value.x, value.y],
                unit: " px",
                isAnimated: clip.anchorPoint.isAnimated,
                isSelected: false,
                keyframeTimes: clip.anchorPoint.keyframes.map { clip.timelineTime(forSourceTime: $0.time) },
                playhead: c.frameTime(animated: animated),
                onReset: {
                    editClip(clip.id) { $0.anchorPoint = AnimatedValue(Vector2.zero) }
                },
                showsReset: { [state = projectState, timelineID] in
                    let current = state?.held?.clipAndLayer(clip.id, in: timelineID)?.clip.anchorPoint ?? clip.anchorPoint
                    return current != AnimatedValue(Vector2.zero)
                },
                onSelect: {},
                onSetComponent: { index, newValue in
                    editClip(clip.id) { clip in
                        var vector = clip.anchorPoint.value(at: c.now.sourceNow)
                        if index == 0 { vector.x = newValue } else { vector.y = newValue }
                        clip.anchorPoint.set(vector, at: c.now.sourceNow)
                    }
                },
                onToggleAnimated: { editClip(clip.id) { $0.anchorPoint.setAnimated(!$0.anchorPoint.isAnimated, at: c.now.sourceNow) } },
                onToggleKeyframe: { editClip(clip.id) { $0.anchorPoint.toggleKeyframe(at: c.now.sourceNow) } },
                onSeek: onSeek,
                onShowGraph: graphs.map { graphs in { graphs.show(key) } }
            ) {
                Button("Reset") { editClip(clip.id) { $0.anchorPoint = AnimatedValue(Vector2.zero) } }
                    .disabled(clip.anchorPoint == AnimatedValue(Vector2.zero))
            },
            lane: ParameterLane(
                marks: clip.anchorPoint.marks, geometry: c.geometry, playhead: c.frameTime(animated: animated), height: EffectsPanelMetrics.rowHeight,
                onSeek: onSeek,
                onMove: { from, to, copy in editClip(clip.id) { $0.anchorPoint.moveKeyframe(at: from, to: to, copying: copy) } },
                onDelete: { time in editClip(clip.id) { $0.anchorPoint.removeKeyframe(at: time) } },
                onEase: { time, preset in editClip(clip.id) { $0.anchorPoint.applyEase(preset, at: time) } }
            )
        )
        .help("Where scale and rotation turn about, from the center of the picture. It is the top of the stack, so it applies to every step.")
    }

    // MARK: Effects

    @ViewBuilder
    private func effectRows(_ effect: Effect, _ c: RowContext) -> some View {
        let clip = c.clip
        let collapsed = state.isCollapsed(effect.id)
        // Sound effects are in a stack of their own, and have no notes
        // about what the picture effects around them do.
        let stack = clip.stack(holding: effect.id) ?? \.effects
        let index = clip[keyPath: stack].index(of: effect.id) ?? 0
        let note = effect.kind.isAudio ? nil : project.note(forEffectAt: index, in: clip, on: c.layer, of: c.timeline)
        // Faded only when it is off or can't apply; one at its defaults is
        // as ready to adjust as any.
        let dimmed = !effect.enabled || note?.dims == true
        // The whole effect, its controls included, is outlined while it is
        // selected: it is what Delete and Copy take. A selected control is
        // outlined on its own instead, as Delete takes only the control.
        let summary = effect.kind.isKeyframing ? project.keyframingSummary(of: effect, in: clip) : nil
        let headerKey = EffectHeaderKey(
            timelineID: timelineID, clip: clip, effect: effect, note: note, collapsed: collapsed, dimmed: dimmed,
            thumbnail: thumbnails[effect.id].map(ObjectIdentifier.init), summary: summary,
            isRenaming: renamingEffectID == effect.id, showUpTo: state.showUpTo,
            canPaste: EditorClipboard.shared.hasEffects,
            showsLanes: showsKeyframeLanes, lane: LaneKey(c.geometry), frameSize: c.timeline.frameSize
        )
        VStack(alignment: .leading, spacing: 0) {
            StackRow(key: headerKey) {
                labelled(
                    EffectHeaderRow(
                        effect: effect,
                        isCollapsed: collapsed,
                        isSelected: false,
                        clipID: clip.id,
                        thumbnail: thumbnails[effect.id],
                        showsCurve: effect.kind.isKeyframing,
                        accessibilitySummary: summary,
                        isDimmed: dimmed,
                        isFlagged: !effect.pasteChanges.isEmpty,
                        onToggleCollapsed: { state.toggleCollapsed(effect.id) },
                        onSetEnabled: { value in editEffect(effect.id, in: clip) { $0.enabled = value } },
                        onSelect: { state.select(effect: effect.id) },
                        onRename: { name in editEffect(effect.id, in: clip) { $0.name = name } },
                        isRenaming: Binding(
                            get: { renamingEffectID == effect.id },
                            // A missing effect keeps the name it was saved with.
                            set: { renamingEffectID = $0 && effect.missing == nil ? effect.id : nil }
                        )
                    ) {
                        effectMenu(effect, in: clip)
                    },
                    lane: emptyLane(c)
                )
            }
            .equatable()
            if let note {
                besideLane(EffectNoteRow(note: note))
            }
            ForEach(effect.pasteChanges) { change in
                pasteChangeRow(change, of: effect, in: clip)
            }
            if !collapsed {
                if effect.kind == .equalizer {
                    PlayheadReader(playhead: playhead) { _ in
                        besideLane(
                            equalizerGraph(effect, of: clip, at: c.sourceNow(animated: true), dimmed: dimmed) {
                                expandedEqualizer = ExpandedEqualizer(clipID: clip.id, effectID: effect.id)
                            }
                            .frame(height: EqualizerGraph.panelHeight)
                        )
                    }
                }
                if effect.kind.isKeyframing {
                    keyframingRows(effect, c, effectDimmed: dimmed)
                }
                ForEach(effect.controls) { control in
                    controlRow(control, of: effect, c, effectDimmed: dimmed)
                }
                if effect.kind.readsAgainst {
                    againstRow(effect, c, effectDimmed: dimmed)
                }
                if effect.kind.takesInput {
                    inputRow(effect, c, effectDimmed: dimmed)
                }
            }
        }
        .selectedRow(state.selectedEffectID == effect.id && state.selectedControlID == nil)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(EffectStackLayout.space)) } action: { frame in
            stackLayout.effects[effect.id] = frame
        }
    }

    /// What a Blending step blends with, or a package's look reads: the
    /// backdrop, or for a look its input or nothing; or the clip's own
    /// picture as it was before one of the effects above it.
    private func againstRow(_ effect: Effect, _ c: RowContext, effectDimmed: Bool) -> some View {
        let clip = c.clip
        let index = clip.effects.index(of: effect.id) ?? 0
        let above = clip.effects.effectsAbove(index)
        // Blending reads the backdrop by default; a look its input, if it
        // takes one (Displace's map).
        let blends = effect.kind == .blending
        let unset = blends ? "Backdrop" : effect.kind.takesInput ? "Its Input" : "None"
        var options: [(id: String, name: String)] = [("backdrop", unset)]
        options += above.map { ($0.id.uuidString, "Before \($0.displayName)") }
        // An effect that is gone, or has been moved below the step, can't be
        // read; the step does nothing until it points somewhere else.
        if let against = effect.against, !above.contains(where: { $0.id == against }) {
            options.append((against.uuidString, "Unavailable"))
        }
        return labelled(
            ChoiceRow(
                name: "Against",
                indent: EffectsPanelMetrics.controlIndent - 12,
                options: options,
                selected: effect.against?.uuidString ?? "backdrop",
                isSelected: false,
                dragHandle: nil,
                showsMenu: false,
                isDimmed: effectDimmed,
                onSelect: {},
                onChoose: { choice in editEffect(effect.id, in: clip) { $0.against = UUID(uuidString: choice) } },
                menu: { EmptyView() }
            ),
            lane: emptyLane(c)
        )
        .help(blends
              ? "What the clip is blended with: the backdrop, or its own picture before an earlier effect"
              : "What it reads besides the picture reaching it: its input, or the clip's own picture before an earlier effect")
    }

    @ViewBuilder
    private func effectMenu(_ effect: Effect, in clip: TimelineClip) -> some View {
        Button("Duplicate") { duplicate(effect, in: clip) }
            .keyboardShortcut("d", modifiers: .command)
        // A missing effect can be turned off, moved, copied and deleted,
        // but what it holds can't be read, so not changed.
        if effect.missing == nil {
            Button("Reset") { editEffect(effect.id, in: clip) { $0.reset(in: timeline?.frameSize) } }
                .disabled(effect.controls.allSatisfy { $0.isNoOp && !$0.isAnimated } && effect.controls.count == effect.kind.controlKinds.count)
            Button("Rename") { renamingEffectID = effect.id }
        }
        Button(effect.enabled ? "Disable" : "Enable") { editEffect(effect.id, in: clip) { $0.enabled.toggle() } }
        if effect.kind.isKeyframing {
            keyframingMenu(effect, clip)
        } else if !effect.kind.isAudio, effect.missing == nil {
            Toggle("Show Up to Here", isOn: Binding(
                get: { state.showUpTo == EffectsPanelState.ShowUpTo(clipID: clip.id, effectID: effect.id) },
                set: { state.showUpTo = $0 ? EffectsPanelState.ShowUpTo(clipID: clip.id, effectID: effect.id) : nil }
            ))
        }
        if effect.kind == .transform {
            Toggle("Moves Anchor", isOn: Binding(
                get: { effect.movesAnchor },
                set: { value in editEffect(effect.id, in: clip) { $0.movesAnchor = value } }
            ))
        }
        if !effect.missingControlKinds.isEmpty {
            Menu("Add Control") {
                ForEach(effect.missingControlKinds) { kind in
                    Button(kind.name) { editEffect(effect.id, in: clip) { $0.addControl(kind) } }
                }
            }
        }
        Divider()
        Button("Copy") { copy(effect, from: clip) }
            .keyboardShortcut("c", modifiers: .command)
        Button("Paste") { paste(in: clip, below: effect) }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!EditorClipboard.shared.hasEffects)
        Button("Save as Preset…") { askPresetName(for: [effect.id], in: clip, suggesting: effect.displayName) }
        Button("Save Whole Stack as Preset…") { askPresetName(for: nil, in: clip, suggesting: "\(project.clipName(clip.id, in: timelineID)) look") }
        Divider()
        Button("Delete", role: .destructive) { delete(effect, from: clip) }
    }

    // MARK: Effect headers

    /// What an effect's header row and its ⋯ menu show, so they are redrawn
    /// only when that changes (see `StackRow`). The Keyframing range items
    /// read the playhead themselves (`keyframingMenu`).
    private struct EffectHeaderKey: Equatable {
        var timelineID: UUID
        var clip: TimelineClip
        var effect: Effect
        var note: EffectNote?
        var collapsed: Bool
        var dimmed: Bool
        var thumbnail: ObjectIdentifier?
        var summary: String?
        var isRenaming: Bool
        var showUpTo: EffectsPanelState.ShowUpTo?
        var canPaste: Bool
        var showsLanes: Bool
        var lane: LaneKey
        var frameSize: CGSize
    }

    // MARK: Clip rows

    /// What the rows of the clip's own (time, anchor, shutter, sound) show,
    /// so they are redrawn only when that changes (see `StackRow`): the
    /// clip, where its lane is, and the playhead only while the value the
    /// row shows is animated.
    private struct ClipRowsKey: Equatable {
        var timelineID: UUID
        var clip: TimelineClip
        var layerID: UUID
        var showsLanes: Bool
        var lane: LaneKey
        var frameSize: CGSize
        var playsVideo: Bool
        var playsAudio: Bool
        var speedBlocked: Bool
    }

    private func clipRows<Content: View>(_ c: RowContext, @ViewBuilder content: @escaping () -> Content) -> some View {
        let key = ClipRowsKey(
            timelineID: timelineID, clip: c.clip, layerID: c.layer.id, showsLanes: showsKeyframeLanes,
            lane: LaneKey(c.geometry), frameSize: c.timeline.frameSize,
            playsVideo: project.playsVideo(c.clip), playsAudio: project.playsAudio(c.clip),
            speedBlocked: speedBlockedClipID == c.clip.id
        )
        return StackRow(key: key, content: content).equatable()
    }

    // MARK: Controls

    /// What a control's row shows, so it is redrawn only when that changes
    /// (see `StackRow`). The whole effect, since a row reads its siblings
    /// (an EQ cut's slope is off with its band) and its default can depend
    /// on them; the playhead only while the control has keyframes, which
    /// its values and lane follow.
    private struct ControlRowKey: Equatable {
        var timelineID: UUID
        var clipID: UUID
        var effect: Effect
        var effectDimmed: Bool
        var isSelected: Bool
        var showsLanes: Bool
        var lane: LaneKey
        var frameSize: CGSize
    }

    private func controlRow(_ control: EffectControl, of effect: Effect, _ c: RowContext, effectDimmed: Bool) -> some View {
        let key = ControlRowKey(
            timelineID: timelineID, clipID: c.clip.id, effect: effect, effectDimmed: effectDimmed,
            isSelected: state.selectedControlID == control.id, showsLanes: showsKeyframeLanes,
            lane: LaneKey(c.geometry), frameSize: c.timeline.frameSize
        )
        return StackRow(key: key) { controlRowContent(control, of: effect, c, effectDimmed: effectDimmed) }
            .equatable()
    }

    /// A control as a held drag has it, for the row to show. A linked size
    /// dragged by its width changes the height too, and an animated value
    /// dragged where it has no keyframe gets one, which its diamond and its
    /// lane show at once; the row reads the project, still as it was. Only
    /// those rows read the held project, so a step of a drag redraws them
    /// and not every row.
    private func heldControl(_ control: EffectControl, of effect: Effect, in clip: TimelineClip) -> EffectControl? {
        guard (control.kind.isLinkable && control.linked) || control.isAnimated, let held = projectState?.held else { return nil }
        return held.clipAndLayer(clip.id, in: timelineID)?.clip.effect(id: effect.id)?.controls.first { $0.id == control.id }
    }

    @ViewBuilder
    private func controlRowContent(_ control: EffectControl, of effect: Effect, _ c: RowContext, effectDimmed: Bool) -> some View {
        let clip = c.clip
        let handle = AnyView(
            Image(systemName: "line.3.horizontal")
                .font(Design.Typeface.glyphTiny)
                .foregroundStyle(Design.textTertiary)
                .frame(width: 12)
                .contentShape(Rectangle())
                .onDrag {
                    ControlMovePayload(clipID: clip.id, effectID: effect.id, controlID: control.id).itemProvider()
                } preview: {
                    Text(control.kind.name).padding(4)
                }
                .help("Drag to move the control within the effect")
        )
        let isSelected = state.selectedControlID == control.id
        let select = { state.select(effect: effect.id, control: control.id) }
        let menu = { controlMenu(control, of: effect, in: clip) }
        let placed = { (frame: CGRect) in stackLayout.controls[control.id] = frame }

        if control.kind.isChoice {
            labelled(
                ChoiceRow(
                    name: control.kind.name,
                    indent: EffectsPanelMetrics.controlIndent - 12,
                    options: control.kind.choiceOptions,
                    selected: control.choice ?? control.kind.defaultChoice ?? "",
                    isSelected: isSelected,
                    dragHandle: handle,
                    isDimmed: effectDimmed || choiceIsOff(control, of: effect),
                    onReset: reset(control, of: effect, in: c),
                    onSelect: select,
                    onChoose: { choice in editControl(control.id, of: effect, in: clip) { $0.choice = choice } },
                    menu: menu
                ),
                lane: emptyLane(c)
            )
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(EffectStackLayout.space)) }, action: placed)
        } else {
            let key = ParameterKey(
                timelineID: timelineID,
                parameter: .control(control.kind, clipID: clip.id, effectID: effect.id, controlID: control.id)
            )
            let shown = heldControl(control, of: effect, in: clip) ?? control
            labelled(
                ParameterRow(
                    name: control.kind.name,
                    indent: EffectsPanelMetrics.controlIndent - 12,
                    components: shown.values(at: c.sourceNow(animated: control.isAnimated)),
                    unit: control.kind.unit,
                    dragStep: control.kind.dragStep,
                    dragRange: { control.kind.range(ofComponent: $0) },
                    componentUnit: EqualizerBand(controlKind: control.kind) == nil ? nil : { control.kind.unit(ofComponent: $0) },
                    componentDragStep: EqualizerBand(controlKind: control.kind) == nil ? nil : { control.kind.dragStep(ofComponent: $0) },
                    isAnimated: control.isAnimated,
                    isSelected: isSelected,
                    keyframeTimes: shown.number.keyframes.map { clip.timelineTime(forSourceTime: $0.time) },
                    playhead: c.frameTime(animated: control.isAnimated),
                    linked: control.kind.isLinkable ? control.linked : nil,
                    onToggleLink: { editControl(control.id, of: effect, in: clip) { $0.linked.toggle() } },
                    dragHandle: handle,
                    isDimmed: effectDimmed || !control.enabled,
                    onReset: resetAction(control, of: effect, in: c),
                    showsReset: resetIsOffered(control, of: effect, in: c),
                    onSelect: select,
                    onSetComponent: { index, value in
                        editControl(control.id, of: effect, in: clip) { $0.setComponent(index, to: value, at: c.now.sourceNow) }
                    },
                    onToggleAnimated: {
                        editControl(control.id, of: effect, in: clip) { $0.number.setAnimated(!$0.number.isAnimated, at: c.now.sourceNow) }
                    },
                    onToggleKeyframe: {
                        editControl(control.id, of: effect, in: clip) { $0.number.toggleKeyframe(at: c.now.sourceNow) }
                    },
                    onSeek: onSeek,
                    onShowGraph: graphs.map { graphs in { graphs.show(key) } },
                    color: control.kind.isColor ? colorBinding(control, of: effect, c) : nil,
                    menu: menu
                ),
                lane: ParameterLane(
                    marks: shown.number.marks, geometry: c.geometry, playhead: c.frameTime(animated: control.isAnimated), height: EffectsPanelMetrics.rowHeight,
                    onSeek: onSeek,
                    onMove: { from, to, copy in
                        editControl(control.id, of: effect, in: clip) { $0.number.moveKeyframe(at: from, to: to, copying: copy) }
                    },
                    onDelete: { time in editControl(control.id, of: effect, in: clip) { $0.number.removeKeyframe(at: time) } },
                    onEase: { time, preset in editControl(control.id, of: effect, in: clip) { $0.number.applyEase(preset, at: time) } }
                )
            )
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(EffectStackLayout.space)) }, action: placed)
        }
    }

    // MARK: EQ

    private func equalizerGraph(_ effect: Effect, of clip: TimelineClip, at time: CMTime, dimmed: Bool, onExpand: (() -> Void)?) -> EqualizerGraph {
        EqualizerGraph(
            effect: effect, time: time, isDimmed: dimmed,
            onEdit: { kind, change in
                editEffect(effect.id, in: clip) { effect in
                    if let index = effect.controls.firstIndex(where: { $0.kind == kind }) { change(&effect.controls[index]) }
                }
            },
            onExpand: onExpand,
            readPaused: pausedSpectrumReader(for: clip)
        )
    }

    /// Reads an EQ's spectrum from the clip's own file while paused: only
    /// a media clip has one. Its source time is the file's, less any shift
    /// from replacing the file.
    private func pausedSpectrumReader(for clip: TimelineClip) -> EqualizerGraph.PausedReader? {
        guard case .media(let mediaID) = clip.source, let media = project.mediaClip(id: mediaID), let url = media.url else { return nil }
        let offset = media.alignmentOffset
        return { pre, effect, time in
            await EqualizerSpectrum.levels(ofFile: url, endingAt: CMTimeAdd(time, offset), through: effect, at: time, pre: pre)
        }
    }

    /// The EQ at a size for fine work, editing the same controls.
    @ViewBuilder
    private func expandedEqualizerSheet(_ item: ExpandedEqualizer) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            if let clip = project.clipAndLayer(item.clipID, in: timelineID)?.clip, let effect = clip.effect(id: item.effectID), let timeline {
                Text("\(project.clipName(clip.id, in: timelineID)) · \(effect.displayName)")
                    .font(Design.Typeface.panelTitle)
                    .foregroundStyle(Design.textPrimary)
                let source = ClipLaneGeometry(clip: clip, timeline: timeline, width: 100)
                    .clampedSource(atTimeline: timeline.snappedToFrame(playheadTime))
                equalizerGraph(effect, of: clip, at: source, dimmed: !effect.enabled, onExpand: nil)
                    .frame(minWidth: 640, minHeight: 320)
                EqualizerBandStrip(effect: effect, time: source) { kind, change in
                    editEffect(effect.id, in: clip) { effect in
                        if let index = effect.controls.firstIndex(where: { $0.kind == kind }) { change(&effect.controls[index]) }
                    }
                }
            } else {
                Text("The EQ is no longer there.").foregroundStyle(Design.textSecondary)
            }
            HStack {
                Text("Drag a band to move it, ⌥-drag or scroll over it to change its Q, double-click to switch it on or off.")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textTertiary)
                Spacer()
                Button("Done") { expandedEqualizer = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Space.group)
    }

    /// Whether a choice changes nothing: an EQ cut's slope does nothing
    /// while its band is off.
    /// What a row's reset button does, nil while the control holds what a
    /// new one would: a shape's size fitted to the frame, as when added.
    private func reset(_ control: EffectControl, of effect: Effect, in c: RowContext) -> (() -> Void)? {
        let fresh = effect.freshControl(control.kind, in: c.timeline.frameSize)
        guard !control.isAtDefault(like: fresh) else { return nil }
        return { editControl(control.id, of: effect, in: c.clip) { $0.reset(to: fresh) } }
    }

    /// What a row's reset button does, which is always there to do; whether
    /// to show it is `resetIsOffered`.
    private func resetAction(_ control: EffectControl, of effect: Effect, in c: RowContext) -> () -> Void {
        let fresh = effect.freshControl(control.kind, in: c.timeline.frameSize)
        return { editControl(control.id, of: effect, in: c.clip) { $0.reset(to: fresh) } }
    }

    /// Whether a row's reset button shows: the control isn't at what a new
    /// one holds. Read as the button draws, from the control as a drag held
    /// to one side of the project has it, so the button appears with the
    /// first step of a drag.
    private func resetIsOffered(_ control: EffectControl, of effect: Effect, in c: RowContext) -> () -> Bool {
        let fresh = effect.freshControl(control.kind, in: c.timeline.frameSize)
        let clipID = c.clip.id
        let (controlID, effectID, timelineID) = (control.id, effect.id, timelineID)
        return { [state = projectState] in
            let held = state?.held?.clipAndLayer(clipID, in: timelineID)?.clip.effect(id: effectID)?.controls.first { $0.id == controlID }
            return !(held ?? control).isAtDefault(like: fresh)
        }
    }

    /// Whether a choice is off: it is, or for a cut's slope, its band is.
    private func choiceIsOff(_ control: EffectControl, of effect: Effect) -> Bool {
        guard let band = EqualizerBand.allCases.first(where: { $0.slopeKind == control.kind }) else { return !control.enabled }
        return !control.enabled || !(effect.control(band.controlKind)?.enabled ?? false)
    }

    /// A color control's value at the playhead as a color (its components
    /// read as sRGB, which is how they are drawn), setting all four at once.
    private func colorBinding(_ control: EffectControl, of effect: Effect, _ c: RowContext) -> Binding<CGColor> {
        Binding(
            get: {
                let rgba = control.values(at: c.sourceNow(animated: control.isAnimated)).map { CGFloat($0) }
                guard rgba.count == 4 else { return CGColor(gray: 1, alpha: 1) }
                return CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
            },
            set: { picked in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let srgb = picked.converted(to: space, intent: .defaultIntent, options: nil),
                      let parts = srgb.components, parts.count >= 4
                else { return }
                let values = parts.prefix(4).map { control.kind.clamped(Double($0)) }
                editControl(control.id, of: effect, in: c.clip) { $0.number.set(ComponentValue(values: values), at: c.now.sourceNow) }
            }
        )
    }

    @ViewBuilder
    private func controlMenu(_ control: EffectControl, of effect: Effect, in clip: TimelineClip) -> some View {
        let fresh = effect.freshControl(control.kind, in: timeline?.frameSize)
        Button("Reset") { editControl(control.id, of: effect, in: clip) { $0.reset(to: fresh) } }
            .disabled(control.isAtDefault(like: fresh))
        if control.kind == .cornerRadius, effect.kind == .rectangle {
            Toggle("Squircle", isOn: Binding(
                get: { control.squircle },
                set: { value in editControl(control.id, of: effect, in: clip) { $0.squircle = value } }
            ))
        }
        Button(control.enabled ? "Disable" : "Enable") { editControl(control.id, of: effect, in: clip) { $0.enabled.toggle() } }
        Divider()
        Button("Delete", role: .destructive) {
            editEffect(effect.id, in: clip) { $0.removeControl(control.id) }
            if state.selectedControlID == control.id { state.select(effect: effect.id) }
        }
    }

    // MARK: Sound

    private func audioRow(_ property: AudioProperty, _ c: RowContext) -> some View {
        let clip = c.clip
        let value = property == .volume ? clip.volume : clip.pan
        let keyPath: WritableKeyPath<TimelineClip, AnimatedValue<Double>> = property == .volume ? \.volume : \.pan
        let parameter: AnimatedParameter = property == .volume ? .clipVolume(clipID: clip.id) : .clipPan(clipID: clip.id)
        let key = ParameterKey(timelineID: timelineID, parameter: parameter)
        return labelled(
            AudioPropertyRow(
                property: property,
                value: value,
                playhead: PlayheadTime(c.playhead) { c.geometry.clampedSource(atTimeline: c.timeline.snappedToFrame($0)) },
                onEdit: { change in editClip(clip.id) { change(&$0[keyPath: keyPath]) } },
                onSeek: { onSeek(clip.timelineTime(forSourceTime: $0)) },
                onShowGraph: graphs.map { graphs in { graphs.show(key) } },
                held: { projectState?.held?.clipAndLayer(clip.id, in: timelineID)?.clip[keyPath: keyPath] }
            )
            .padding(.horizontal, 8),
            lane: ParameterLane(
                marks: (projectState?.held?.clipAndLayer(clip.id, in: timelineID)?.clip[keyPath: keyPath] ?? value).marks,
                geometry: c.geometry, playhead: c.frameTime(animated: value.isAnimated), height: EffectsPanelMetrics.rowHeight,
                onSeek: onSeek,
                onMove: { from, to, copy in editClip(clip.id) { $0[keyPath: keyPath].moveKeyframe(at: from, to: to, copying: copy) } },
                onDelete: { time in editClip(clip.id) { $0[keyPath: keyPath].removeKeyframe(at: time) } },
                onEase: { time, preset in editClip(clip.id) { $0[keyPath: keyPath].applyEase(preset, at: time) } }
            )
        )
    }

    // MARK: Editing

    func editClip(_ id: UUID, _ change: (inout TimelineClip) -> Void) {
        project.editClip(id, in: timelineID, change)
    }

    private func editEffect(_ id: UUID, in clip: TimelineClip, _ change: (inout Effect) -> Void) {
        project.editEffect(id, ofClip: clip.id, in: timelineID, change)
    }

    private func editControl(_ id: UUID, of effect: Effect, in clip: TimelineClip, _ change: (inout EffectControl) -> Void) {
        editEffect(effect.id, in: clip) { effect in
            if let index = effect.controlIndex(id) { change(&effect.controls[index]) }
        }
    }

    private func addEffect(_ kind: EffectKind, to clip: TimelineClip) {
        if let id = project.addEffect(kind, toClip: clip.id, in: timelineID) {
            state.select(effect: id)
        }
    }

    private func duplicate(_ effect: Effect, in clip: TimelineClip) {
        if let id = project.duplicateEffect(effect.id, ofClip: clip.id, in: timelineID) {
            state.select(effect: id)
        }
    }

    private func copy(_ effect: Effect, from clip: TimelineClip) {
        EditorClipboard.shared.copy(effects: project.bundle(ofEffects: [effect.id], fromClip: clip.id, in: timelineID))
    }

    /// Pastes the copied effects below `effect`, or at the end of the stack.
    private func paste(in clip: TimelineClip, below effect: Effect?) {
        guard let bundle = EditorClipboard.shared.effects else { return }
        // Below the effect when the first copied one goes in its stack.
        let index = effect.flatMap { effect -> Int? in
            guard bundle.effects.first?.effect.kind.isAudio == effect.kind.isAudio,
                  let stack = clip.stack(holding: effect.id)
            else { return nil }
            return clip[keyPath: stack].index(of: effect.id).map { $0 + 1 }
        }
        if let last = project.paste(bundle, ontoClip: clip.id, in: timelineID, at: index).last {
            state.select(effect: last)
        }
    }

    /// A drop on the stack (`EffectStackDropDelegate`): an effect of this
    /// clip moved to the place, or with Option copied there; a control
    /// moved within its effect; an effect or preset from the library put
    /// in at the place. What lands is selected.
    private func dropOnStack(_ target: EffectStackTarget, _ payload: ClipDropPayload, copy: Bool) {
        guard let clip = selectedClip else { return }
        switch target {
        case .effects(let isAudio, let index):
            if let move = payload.effectMove {
                guard move.clipID == clip.id, let index, let stack = clip.stack(holding: move.effectID),
                      (stack == \TimelineClip.audioEffects) == isAudio, let from = clip[keyPath: stack].index(of: move.effectID)
                else { return }
                if copy {
                    guard let copyID = project.duplicateEffect(move.effectID, ofClip: clip.id, in: timelineID) else { return }
                    project.moveEffect(copyID, ofClip: clip.id, in: timelineID, toIndex: index)
                    state.select(effect: copyID)
                } else {
                    // Taking it out first shifts the places after it up one.
                    project.moveEffect(move.effectID, ofClip: clip.id, in: timelineID, toIndex: index > from ? index - 1 : index)
                    state.select(effect: move.effectID)
                }
            } else if let added = payload.effect {
                // One of the other stack goes at the end of its own.
                let at = added.kind.isAudio == isAudio ? index : nil
                if let id = project.addEffect(added.kind, toClip: clip.id, in: timelineID, at: at) {
                    state.select(effect: id)
                }
            } else if let preset = payload.preset {
                _ = applyPreset(preset.presetID, to: clip, at: index)
            }
        case .controls(let effectID, let index):
            guard let move = payload.controlMove, move.clipID == clip.id, move.effectID == effectID,
                  let effect = clip.effect(id: effectID), let from = effect.controlIndex(move.controlID)
            else { return }
            editEffect(effectID, in: clip) { $0.moveControl(move.controlID, toIndex: index > from ? index - 1 : index) }
            state.select(effect: effectID, control: move.controlID)
        }
    }

    private func applyPreset(_ id: String, to clip: TimelineClip, at index: Int?) -> Bool {
        guard let preset = try? PresetStore.read(PresetStore.fileURL(id)) else { return false }
        guard let last = project.paste(preset.bundle, ontoClip: clip.id, in: timelineID, at: index).last else { return false }
        state.select(effect: last)
        return true
    }

    private func askPresetName(for ids: Set<UUID>?, in clip: TimelineClip, suggesting name: String) {
        presetName = name
        presetSave = PresetSave(clipID: clip.id, effectIDs: ids, suggestedName: name)
    }

    private func savePreset() {
        guard let request = presetSave else { return }
        presetSave = nil
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let bundle = project.bundle(ofEffects: request.effectIDs, fromClip: request.clipID, in: timelineID) else { return }
        do {
            try PresetStore.save(bundle, named: name)
            NotificationCenter.default.post(name: .presetsChanged, object: nil)
        } catch {
            presetError = error.localizedDescription
        }
    }

    private func delete(_ effect: Effect, from clip: TimelineClip) {
        project.removeEffect(effect.id, fromClip: clip.id, in: timelineID)
        if state.selectedEffectID == effect.id { state.clear() }
    }

    /// Removes the selected control, or else the selected effect.
    private func deleteSelection(_ effect: Effect, in clip: TimelineClip) {
        if let controlID = state.selectedControlID {
            editEffect(effect.id, in: clip) { $0.removeControl(controlID) }
            state.select(effect: effect.id)
        } else {
            delete(effect, from: clip)
        }
    }

    /// What the Edit menu does here (see `EditCommands`): with an effect
    /// selected, the commands are the effect's; Paste puts copied effects
    /// in the selected clip's stack, below the selected effect. A clip
    /// copied last is the timeline's to paste.
    private var editActions: EditMenuActions? {
        guard let clip = selectedClip else { return nil }
        let effect = state.selectedEffectID.flatMap { clip.effect(id: $0) }
        let clipboard = EditorClipboard.shared
        let canPaste = clipboard.hasEffects && clipboard.clip == nil && (project.hasEffectStack(clip) || project.playsAudio(clip))
        let onEffect = { (action: @escaping (Effect) -> Void) -> (() -> Void)? in
            effect.map { effect in { action(effect) } }
        }
        return EditMenuActions(
            cut: onEffect { effect in
                copy(effect, from: clip)
                delete(effect, from: clip)
            },
            copy: onEffect { copy($0, from: clip) },
            paste: canPaste ? { paste(in: clip, below: effect) } : nil,
            duplicate: onEffect { duplicate($0, in: clip) },
            delete: onEffect { deleteSelection($0, in: clip) },
            state: [clip.id, effect?.id, state.selectedControlID, canPaste] as [AnyHashable?]
        )
    }

    /// Delete removes the selected control, or else the selected effect;
    /// Command-D duplicates the selected effect.
    private func handleKey(_ event: NSEvent) -> Bool {
        // Another panel was clicked in last: the keys are its.
        guard (activePanel?.current ?? .sidePanel) == .sidePanel else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        // Command-V pastes below the selected effect, or at the end of the
        // selected clip's stack; a clip copied last is the timeline's to
        // paste.
        if flags == .command, key == "v", let clip = selectedClip, project.hasEffectStack(clip) || project.playsAudio(clip),
           EditorClipboard.shared.hasEffects, EditorClipboard.shared.clip == nil {
            paste(in: clip, below: state.selectedEffectID.flatMap { clip.effect(id: $0) })
            return true
        }
        guard let clip = selectedClip, let effectID = state.selectedEffectID,
              let effect = clip.effect(id: effectID)
        else {
            return false
        }
        if flags == .command, key == "c" {
            copy(effect, from: clip)
            return true
        }
        if [51, 117].contains(event.keyCode), flags.isEmpty {
            deleteSelection(effect, in: clip)
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "d" {
            duplicate(effect, in: clip)
            return true
        }
        return false
    }
}
