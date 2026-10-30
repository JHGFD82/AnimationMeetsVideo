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
    @Environment(ProjectState.self) var projectState: ProjectState?
    /// The surface's graph editor panels.
    @Environment(KeyframeGraphHUDs.self) var graphs: KeyframeGraphHUDs?
    /// Whether each row shows its keyframe lane, with the ruler and
    /// playhead over them. Kept between launches.
    @AppStorage(Preferences.effectsPanelShowsKeyframeLanes) var showsKeyframeLanes = true
    @State var renamingEffectID: UUID?
    /// The clip whose speed was last refused for crossing zero, until its
    /// speed is next edited.
    @State var speedBlockedClipID: UUID?
    /// Effects being saved as a preset (nil for the whole stack), while the
    /// name is asked for.
    @State private var presetSave: PresetSave?
    /// Where the stack's rows are, for drops on it, and the line showing
    /// where a drag over it would go.
    @State var stackLayout = EffectStackLayout()
    @State private var stackScroller = EdgeAutoScroll()
    /// The control column's width and the lanes' zoom and scroll.
    @State var lanes = LaneViewport()
    @State private var dropLine: CGFloat?
    /// A lasso being dragged across the lanes, in window coordinates.
    @State var keyframeLasso: KeyframeLasso?
    /// Where the stack's scroll view is, in window coordinates, for telling
    /// where a press in the lanes lands.
    @State var stackFrame: CGRect = .zero
    /// The editor's active panel, which has the keys. Read as a key comes
    /// in, not while drawing, so becoming active doesn't redraw the stack.
    @Environment(ActivePanel.self) private var activePanel: ActivePanel?
    @State private var presetName = ""
    @State private var presetError: String?
    /// The clip after each of its effects, at the playhead.
    @State var thumbnails: [UUID: CGImage] = [:]
    /// The EQ shown larger in a sheet.
    @State var expandedEqualizer: ExpandedEqualizer?

    struct ExpandedEqualizer: Identifiable {
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
        // Over the lanes while a keyframe on them is dragged.
        .dragTimecodeReadout(frameRate: timeline?.frameRate ?? 0)
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
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stackFrame = $0 }
                .background { if showsKeyframeLanes { keyframeLassoMonitor } }
                .overlay { keyframeLassoOverlay }
            }
            .environment(lanes)
            .environment(state.keyframes)
            .onPreferenceChange(ControlColumnWidthKey.self) { width in
                lanes.labelWidth = max(lanes.labelWidth, width.rounded(.up))
            }
            .onChange(of: laneWidth, initial: true) { _, width in lanes.fit(width: width, maxZoom: maxZoom) }
            .onChange(of: maxZoom) { _, zoom in lanes.fit(width: laneWidth, maxZoom: zoom) }
            .onChange(of: clip.id) { _, _ in
                lanes.reset()
                state.keyframes.clear()
            }
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
                    lanes.scroll(byPoints: deltaX, phase: phase)
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
            // A shape or text clip's drawing is what the clip is, so it
            // heads the panel, pinned, rather than sitting in its stack.
            ForEach(clip.drawingEffects) { effect in
                effectRows(effect, c, isDrawing: true)
            }
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
                ForEach(clip.stackEffects) { effect in
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

    // MARK: Editing

    func editClip(_ id: UUID, _ change: (inout TimelineClip) -> Void) {
        project.editClip(id, in: timelineID, change)
    }

    func editEffect(_ id: UUID, in clip: TimelineClip, _ change: (inout Effect) -> Void) {
        project.editEffect(id, ofClip: clip.id, in: timelineID, change)
    }

    func editControl(_ id: UUID, of effect: Effect, in clip: TimelineClip, _ change: (inout EffectControl) -> Void) {
        editEffect(effect.id, in: clip) { effect in
            if let index = effect.controlIndex(id) { change(&effect.controls[index]) }
        }
    }

    private func addEffect(_ kind: EffectKind, to clip: TimelineClip) {
        if let id = project.addEffect(kind, toClip: clip.id, in: timelineID) {
            state.select(effect: id)
        }
    }

    func duplicate(_ effect: Effect, in clip: TimelineClip) {
        if let id = project.duplicateEffect(effect.id, ofClip: clip.id, in: timelineID) {
            state.select(effect: id)
        }
    }

    func copy(_ effect: Effect, from clip: TimelineClip) {
        copy([effect], from: clip)
    }

    func copy(_ effects: [Effect], from clip: TimelineClip) {
        EditorClipboard.shared.copy(effects: project.bundle(ofEffects: Set(effects.map(\.id)), fromClip: clip.id, in: timelineID))
    }

    /// Pastes the copied effects below `effect`, or at the end of the stack.
    func paste(in clip: TimelineClip, below effect: Effect?) {
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
        case .effects(let isAudio, let shownIndex):
            // The drop target counts the rows shown; a shape or text
            // clip's drawing is pinned apart from the stack, so a place
            // among the rest is turned into one among all its effects.
            let index = isAudio ? shownIndex : shownIndex.map { stackIndex(forShown: $0, in: clip) }
            if let move = payload.effectMove {
                guard !clip.isDrawing(move.effectID) else { return }
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
        case .controls(let effectID, let shownIndex):
            guard let move = payload.controlMove, move.clipID == clip.id, move.effectID == effectID,
                  let effect = clip.effect(id: effectID), let from = effect.controlIndex(move.controlID)
            else { return }
            // The drop target counts the controls shown, which leave out a
            // shape's choices: a place among them is turned into one among
            // all of the effect's controls.
            let shown = effect.controls.filter { effect.kind.panelLists($0.kind) }
            let index = shownIndex < shown.count ? effect.controlIndex(shown[shownIndex].id) ?? from : effect.controls.count
            editEffect(effectID, in: clip) { $0.moveControl(move.controlID, toIndex: index > from ? index - 1 : index) }
            state.select(effect: effectID, control: move.controlID)
        }
    }

    /// The place in `clip.effects` of the place `shown` among the effects
    /// the stack lists (`TimelineClip.stackEffects`): before the one
    /// listed there, or at the end.
    private func stackIndex(forShown shown: Int, in clip: TimelineClip) -> Int {
        let listed = clip.stackEffects
        guard shown < listed.count else { return clip.effects.count }
        return clip.effects.index(of: listed[shown].id) ?? clip.effects.count
    }

    private func applyPreset(_ id: String, to clip: TimelineClip, at index: Int?) -> Bool {
        guard let preset = try? PresetStore.read(PresetStore.fileURL(id)) else { return false }
        guard let last = project.paste(preset.bundle, ontoClip: clip.id, in: timelineID, at: index).last else { return false }
        state.select(effect: last)
        return true
    }

    func askPresetName(for ids: Set<UUID>?, in clip: TimelineClip, suggesting name: String) {
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

    func delete(_ effect: Effect, from clip: TimelineClip) {
        project.removeEffect(effect.id, fromClip: clip.id, in: timelineID)
        if state.selectedEffectID == effect.id { state.clear() }
    }

    /// The panel's effects and their listed controls, top to bottom, which
    /// Shift-click picks a run of.
    func rowOrder(_ clip: TimelineClip) -> [UUID] {
        (clip.effects + clip.audioEffects).flatMap { effect in
            [effect.id] + effect.panelSections().flatMap(\.controls).map(\.id)
        }
    }

    /// The picked effects that can be copied, in stack order: not a shape
    /// or text clip's drawing.
    private func pickedEffects(of clip: TimelineClip) -> [Effect] {
        (clip.effects + clip.audioEffects).filter { state.isPicked($0.id) && !clip.isDrawing($0.id) }
    }

    /// Removes every picked effect and control, as one edit; a drawing
    /// stays, its picked controls going.
    private func deletePickedRows(in clip: TimelineClip) {
        for effect in clip.effects + clip.audioEffects {
            if state.isPicked(effect.id), !clip.isDrawing(effect.id) {
                project.removeEffect(effect.id, fromClip: clip.id, in: timelineID)
                continue
            }
            let controls = effect.controls.map(\.id).filter(state.isPicked)
            if !controls.isEmpty {
                editEffect(effect.id, in: clip) { effect in for id in controls { effect.removeControl(id) } }
            }
        }
        state.clear()
    }

    /// Removes the selected control, or else the selected effect; a shape
    /// or text clip's drawing stays. Several rows picked, all of them.
    private func deleteSelection(_ effect: Effect, in clip: TimelineClip) {
        if state.picksSeveralRows { return deletePickedRows(in: clip) }
        if let controlID = state.selectedControlID {
            editEffect(effect.id, in: clip) { $0.removeControl(controlID) }
            state.select(effect: effect.id)
        } else if !clip.isDrawing(effect.id) {
            delete(effect, from: clip)
        }
    }

    /// What the Edit menu does here (see `EditCommands`): with an effect
    /// selected, the commands are the effect's; Paste puts copied effects
    /// in the selected clip's stack, below the selected effect. A clip
    /// copied last is the timeline's to paste.
    private var editActions: EditMenuActions? {
        guard let clip = selectedClip else { return nil }
        let selected = state.selectedEffectID.flatMap { clip.effect(id: $0) }
        // A shape or text clip's drawing isn't an effect to cut, copy or
        // duplicate; Delete still takes one of its selected controls.
        let effect = selected.flatMap { clip.isDrawing($0.id) ? nil : $0 }
        let clipboard = EditorClipboard.shared
        let canPaste = clipboard.hasEffects && clipboard.clip == nil && (project.hasEffectStack(clip) || project.playsAudio(clip))
        // Several effects picked are cut, copied and duplicated together.
        let several = state.picksSeveralRows ? pickedEffects(of: clip) : []
        let onEffect = { (action: @escaping ([Effect]) -> Void) -> (() -> Void)? in
            if !several.isEmpty { return { action(several) } }
            return effect.map { effect in { action([effect]) } }
        }
        let keyframes = state.keyframes
        var delete: (() -> Void)? = (state.selectedControlID == nil ? effect : selected).map { effect in { deleteSelection(effect, in: clip) } }
        if !keyframes.isEmpty { delete = { _ = keyframes.deletePicked() } }
        return EditMenuActions(
            cut: onEffect { effects in
                copy(effects, from: clip)
                for effect in effects { self.delete(effect, from: clip) }
            },
            copy: onEffect { copy($0, from: clip) },
            paste: canPaste ? { paste(in: clip, below: effect) } : nil,
            duplicate: onEffect { effects in for effect in effects { duplicate(effect, in: clip) } },
            delete: delete,
            state: [clip.id, effect?.id, state.selectedControlID, canPaste, state.pickedRows, keyframes.picked] as [AnyHashable?]
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
        // Keyframes picked in the lanes take Delete, ← and → (ten frames
        // with Shift), and Escape lets go of them; ⌘A picks every one.
        if [51, 117].contains(event.keyCode), flags.isEmpty, state.keyframes.deletePicked() { return true }
        if [123, 124].contains(event.keyCode), flags.isDisjoint(with: [.command, .control, .option]), !state.keyframes.isEmpty,
           !(event.window?.firstResponder is NSText) {
            let frames = (event.keyCode == 123 ? -1 : 1) * (flags.contains(.shift) ? 10 : 1)
            return state.keyframes.nudge(frames: frames)
        }
        if flags == .command, key == "a", showsKeyframeLanes, !(event.window?.firstResponder is NSText), state.keyframes.selectAll() {
            return true
        }
        if event.keyCode == 53, flags.isEmpty, !state.keyframes.isEmpty, !ValueDragSession.isActive {
            state.keyframes.clear()
            return true
        }
        if let clip = selectedClip, state.picksSeveralRows {
            let effects = pickedEffects(of: clip)
            if flags == .command, key == "c", !effects.isEmpty {
                copy(effects, from: clip)
                return true
            }
            if [51, 117].contains(event.keyCode), flags.isEmpty {
                deletePickedRows(in: clip)
                return true
            }
            if flags == .command, key == "d", !effects.isEmpty {
                for effect in effects { duplicate(effect, in: clip) }
                return true
            }
        }
        guard let clip = selectedClip, let effectID = state.selectedEffectID,
              let effect = clip.effect(id: effectID)
        else {
            return false
        }
        let isDrawing = clip.isDrawing(effect.id)
        if flags == .command, key == "c", !isDrawing {
            copy(effect, from: clip)
            return true
        }
        if [51, 117].contains(event.keyCode), flags.isEmpty {
            deleteSelection(effect, in: clip)
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "d", !isDrawing {
            duplicate(effect, in: clip)
            return true
        }
        return false
    }
}
