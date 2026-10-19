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
    let playheadTime: CMTime
    let state: EffectsPanelState
    let onSeek: (CMTime) -> Void
    let onSelectTransition: (TransitionEdge) -> Void
    /// The player, which the playhead line follows while it plays; the
    /// rest of the panel stays at `playheadTime`, so playing redraws only
    /// the line. Nil leaves the line parked.
    var playback: PlaybackModel?

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
        .alert("Save as Preset", isPresented: Binding(get: { presetSave != nil }, set: { if !$0 { presetSave = nil } })) {
            TextField("Name", text: $presetName)
            Button("Save", action: savePreset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Presets are shared by every project and appear in the browser.")
        }
        .alert("The Preset Wasn't Saved", isPresented: Binding(get: { presetError != nil }, set: { if !$0 { presetError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presetError ?? "")
        }
        .sheet(item: $expandedEqualizer) { item in
            expandedEqualizerSheet(item)
        }
        .onChange(of: selection) { _, _ in
            state.clear()
            renamingEffectID = nil
        }
        // Refreshed when the playhead stops, or the stack changes.
        .task(id: thumbnailRequest) {
            guard let request = thumbnailRequest else {
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
    }

    /// What the thumbnails are drawn from; they are drawn again when it
    /// changes.
    private struct ThumbnailRequest: Equatable {
        var clipID: UUID
        var effects: [Effect]
        var anchorPoint: AnimatedValue<Vector2>
        var time: CMTime
    }

    private var thumbnailRequest: ThumbnailRequest? {
        guard let clip = selectedClip, let timeline, project.hasEffectStack(clip), !clip.effects.isEmpty else { return nil }
        return ThumbnailRequest(clipID: clip.id, effects: clip.effects, anchorPoint: clip.anchorPoint, time: timeline.snappedToFrame(playheadTime))
    }

    // MARK: Stack

    private func stack(of clip: TimelineClip, in timeline: Timeline) -> some View {
        GeometryReader { proxy in
            let laneWidth = max(80, proxy.size.width - EffectsPanelMetrics.labelWidth - 2 * EffectsPanelMetrics.laneInset)
            let geometry = ClipLaneGeometry(clip: clip, timeline: timeline, width: laneWidth)
            let frameTime = timeline.snappedToFrame(playheadTime)
            let sourceNow = geometry.clampedSource(atTimeline: frameTime)
            let layer = project.clipAndLayer(clip.id, in: timelineID)?.layer
            let context = RowContext(
                clip: clip, timeline: timeline, layer: layer ?? TimelineLayer(clips: []),
                geometry: geometry, frameTime: frameTime, sourceNow: sourceNow
            )

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Stack")
                        .font(Design.Typeface.micro)
                        .foregroundStyle(Design.textTertiary)
                        .padding(.leading, 8)
                        .frame(width: EffectsPanelMetrics.labelWidth, alignment: .leading)
                    if showsKeyframeLanes {
                        PanelRuler(geometry: geometry, onSeek: onSeek)
                            .overlay(alignment: .topLeading) { rangeBar(clip, geometry: geometry) }
                            .padding(.horizontal, EffectsPanelMetrics.laneInset)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: PanelRuler.height)
                .background(Design.Surface.raised.color)

                ScrollView {
                    rows(context)
                        .overlay(alignment: .topLeading) { if showsKeyframeLanes { playheadLine(context) } }
                        .dropDestination(for: ClipDropPayload.self) { payloads, _ in
                            guard let payload = payloads.first else { return false }
                            if let effect = payload.effect {
                                addEffect(effect.kind, to: clip)
                                return true
                            }
                            if let preset = payload.preset { return applyPreset(preset.presetID, to: clip, at: nil) }
                            return false
                        }
                }
                .sunken(.sunken)
            }
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
    struct RowContext {
        let clip: TimelineClip
        let timeline: Timeline
        /// The layer the clip is on.
        let layer: TimelineLayer
        let geometry: ClipLaneGeometry
        /// The playhead on a frame, in the timeline's time.
        let frameTime: CMTime
        /// The clip's source time at the playhead, held inside the clip.
        let sourceNow: CMTime
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
            timeRows(c)
            if project.hasEffectStack(clip) {
                anchorRow(c)
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
            shutterRows(c)
            if project.playsAudio(clip) {
                // Sound comes after pictures: its effects, then its volume
                // and pan, in the order it is played through them.
                ForEach(clip.audioEffects) { effect in
                    effectRows(effect, c)
                }
                audioRow(.volume, c)
                audioRow(.pan, c)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 0, alignment: .top)
    }

    func labelled<Label: View, Lane: View>(_ label: Label, lane: Lane) -> some View {
        HStack(spacing: 0) {
            if showsKeyframeLanes {
                label.frame(width: EffectsPanelMetrics.labelWidth, alignment: .leading)
                lane
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
                content.frame(width: EffectsPanelMetrics.labelWidth, alignment: .leading)
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
        LanePlayheadLine(playback: playback, parked: c.frameTime, geometry: c.geometry)
            .allowsHitTesting(false)
    }

    // MARK: Anchor point

    private func anchorRow(_ c: RowContext) -> some View {
        let clip = c.clip
        let value = clip.anchorPoint.value(at: c.sourceNow)
        let key = ParameterKey(timelineID: timelineID, parameter: .anchorPoint(clipID: clip.id))
        return labelled(
            ParameterRow(
                name: "Anchor",
                components: [value.x, value.y],
                unit: " px",
                isAnimated: clip.anchorPoint.isAnimated,
                isSelected: false,
                keyframeTimes: clip.anchorPoint.keyframes.map { clip.timelineTime(forSourceTime: $0.time) },
                playhead: c.frameTime,
                onReset: clip.anchorPoint == AnimatedValue(Vector2.zero) ? nil : {
                    editClip(clip.id) { $0.anchorPoint = AnimatedValue(Vector2.zero) }
                },
                onSelect: {},
                onSetComponent: { index, newValue in
                    editClip(clip.id) { clip in
                        var vector = clip.anchorPoint.value(at: c.sourceNow)
                        if index == 0 { vector.x = newValue } else { vector.y = newValue }
                        clip.anchorPoint.set(vector, at: c.sourceNow)
                    }
                },
                onToggleAnimated: { editClip(clip.id) { $0.anchorPoint.setAnimated(!$0.anchorPoint.isAnimated, at: c.sourceNow) } },
                onToggleKeyframe: { editClip(clip.id) { $0.anchorPoint.toggleKeyframe(at: c.sourceNow) } },
                onSeek: onSeek,
                onShowGraph: graphs.map { graphs in { graphs.show(key) } }
            ) {
                Button("Reset") { editClip(clip.id) { $0.anchorPoint = AnimatedValue(Vector2.zero) } }
                    .disabled(clip.anchorPoint == AnimatedValue(Vector2.zero))
            },
            lane: ParameterLane(
                marks: clip.anchorPoint.marks, geometry: c.geometry, playhead: c.frameTime, height: EffectsPanelMetrics.rowHeight,
                onSeek: onSeek,
                onMove: { from, to in editClip(clip.id) { $0.anchorPoint.moveKeyframe(at: from, to: to) } },
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
        labelled(
            EffectHeaderRow(
                effect: effect,
                isCollapsed: collapsed,
                isSelected: state.selectedEffectID == effect.id && state.selectedControlID == nil,
                clipID: clip.id,
                thumbnail: thumbnails[effect.id],
                showsCurve: effect.kind.isKeyframing,
                accessibilitySummary: effect.kind.isKeyframing ? project.keyframingSummary(of: effect, in: clip) : nil,
                isDimmed: dimmed,
                isFlagged: !effect.pasteChanges.isEmpty,
                onToggleCollapsed: { state.toggleCollapsed(effect.id) },
                onSetEnabled: { value in editEffect(effect.id, in: clip) { $0.enabled = value } },
                onSelect: { state.select(effect: effect.id) },
                onRename: { name in editEffect(effect.id, in: clip) { $0.name = name } },
                isRenaming: Binding(
                    get: { renamingEffectID == effect.id },
                    set: { renamingEffectID = $0 ? effect.id : nil }
                )
            ) {
                effectMenu(effect, in: clip)
            },
            lane: emptyLane(c)
        )
        .dropDestination(for: ClipDropPayload.self) { payloads, _ in
            guard let payload = payloads.first, let index = clip[keyPath: stack].index(of: effect.id) else { return false }
            if let move = payload.effectMove {
                // An effect moves only within its own stack.
                guard move.clipID == clip.id, clip.stack(holding: move.effectID) == stack else { return false }
                project.moveEffect(move.effectID, ofClip: clip.id, in: timelineID, toIndex: index)
                return true
            }
            if let added = payload.effect {
                // Dropped on an effect: it goes in at that place and is
                // selected, as one dropped below the stack is. One of the
                // other stack goes at the end of its own.
                let at = added.kind.isAudio == effect.kind.isAudio ? index : nil
                if let id = project.addEffect(added.kind, toClip: clip.id, in: timelineID, at: at) {
                    state.select(effect: id)
                }
                return true
            }
            if let preset = payload.preset { return applyPreset(preset.presetID, to: clip, at: index) }
            return false
        }
        if let note {
            besideLane(EffectNoteRow(note: note))
        }
        ForEach(effect.pasteChanges) { change in
            pasteChangeRow(change, of: effect, in: clip)
        }
        if !collapsed {
            if effect.kind == .equalizer {
                besideLane(
                    equalizerGraph(effect, of: clip, at: c.sourceNow, dimmed: dimmed) {
                        expandedEqualizer = ExpandedEqualizer(clipID: clip.id, effectID: effect.id)
                    }
                    .frame(height: EqualizerGraph.panelHeight)
                )
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

    /// What a Blending step blends with: the backdrop, or the clip's own
    /// picture as it was before one of the effects above it.
    private func againstRow(_ effect: Effect, _ c: RowContext, effectDimmed: Bool) -> some View {
        let clip = c.clip
        let index = clip.effects.index(of: effect.id) ?? 0
        let above = clip.effects.effectsAbove(index)
        // Blending reads the backdrop by default; Displace its input, as
        // the map.
        let displaces = effect.kind == .displace
        var options: [(id: String, name: String)] = [("backdrop", displaces ? "Its Input" : "Backdrop")]
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
        .help(displaces
              ? "What is moved: its input, by the picture reaching this step; or the clip's own picture before an earlier effect, by the picture reaching it"
              : "What the clip is blended with: the backdrop, or its own picture before an earlier effect")
    }

    @ViewBuilder
    private func effectMenu(_ effect: Effect, in clip: TimelineClip) -> some View {
        Button("Duplicate") { duplicate(effect, in: clip) }
            .keyboardShortcut("d", modifiers: .command)
        Button("Reset") { editEffect(effect.id, in: clip) { $0.reset(in: timeline?.frameSize) } }
            .disabled(effect.controls.allSatisfy { $0.isNoOp && !$0.isAnimated } && effect.controls.count == effect.kind.controlKinds.count)
        Button("Rename") { renamingEffectID = effect.id }
        Button(effect.enabled ? "Disable" : "Enable") { editEffect(effect.id, in: clip) { $0.enabled.toggle() } }
        if effect.kind.isKeyframing {
            keyframingMenu(effect, clip)
        } else if !effect.kind.isAudio {
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
            .disabled(EffectClipboard.shared.isEmpty)
        Button("Save as Preset…") { askPresetName(for: [effect.id], in: clip, suggesting: effect.displayName) }
        Button("Save Whole Stack as Preset…") { askPresetName(for: nil, in: clip, suggesting: "\(project.clipName(clip.id, in: timelineID)) look") }
        Divider()
        Button("Delete", role: .destructive) { delete(effect, from: clip) }
    }

    // MARK: Controls

    @ViewBuilder
    private func controlRow(_ control: EffectControl, of effect: Effect, _ c: RowContext, effectDimmed: Bool) -> some View {
        let clip = c.clip
        let handle = AnyView(
            Image(systemName: "line.3.horizontal")
                .font(Design.Typeface.glyphTiny)
                .foregroundStyle(Design.textTertiary)
                .frame(width: 12)
                .contentShape(Rectangle())
                .draggable(ControlMovePayload(clipID: clip.id, effectID: effect.id, controlID: control.id)) {
                    Text(control.kind.name).padding(4)
                }
                .help("Drag to move the control within the effect")
        )
        let isSelected = state.selectedControlID == control.id
        let select = { state.select(effect: effect.id, control: control.id) }
        let menu = { controlMenu(control, of: effect, in: clip) }
        let dropControl: ([ControlMovePayload], CGPoint) -> Bool = { payloads, _ in
            guard let payload = payloads.first, payload.clipID == clip.id, payload.effectID == effect.id,
                  let index = effect.controlIndex(control.id)
            else { return false }
            editEffect(effect.id, in: clip) { $0.moveControl(payload.controlID, toIndex: index) }
            return true
        }

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
            .dropDestination(for: ControlMovePayload.self, action: dropControl)
        } else {
            let key = ParameterKey(
                timelineID: timelineID,
                parameter: .control(control.kind, clipID: clip.id, effectID: effect.id, controlID: control.id)
            )
            labelled(
                ParameterRow(
                    name: control.kind.name,
                    indent: EffectsPanelMetrics.controlIndent - 12,
                    components: control.values(at: c.sourceNow),
                    unit: control.kind.unit,
                    dragStep: control.kind.dragStep,
                    dragRange: { control.kind.range(ofComponent: $0) },
                    componentUnit: EqualizerBand(controlKind: control.kind) == nil ? nil : { control.kind.unit(ofComponent: $0) },
                    componentDragStep: EqualizerBand(controlKind: control.kind) == nil ? nil : { control.kind.dragStep(ofComponent: $0) },
                    isAnimated: control.isAnimated,
                    isSelected: isSelected,
                    keyframeTimes: control.number.keyframes.map { clip.timelineTime(forSourceTime: $0.time) },
                    playhead: c.frameTime,
                    linked: control.kind.isLinkable ? control.linked : nil,
                    onToggleLink: { editControl(control.id, of: effect, in: clip) { $0.linked.toggle() } },
                    dragHandle: handle,
                    isDimmed: effectDimmed || !control.enabled,
                    onReset: reset(control, of: effect, in: c),
                    onSelect: select,
                    onSetComponent: { index, value in
                        editControl(control.id, of: effect, in: clip) { $0.setComponent(index, to: value, at: c.sourceNow) }
                    },
                    onToggleAnimated: {
                        editControl(control.id, of: effect, in: clip) { $0.number.setAnimated(!$0.number.isAnimated, at: c.sourceNow) }
                    },
                    onToggleKeyframe: {
                        editControl(control.id, of: effect, in: clip) { $0.number.toggleKeyframe(at: c.sourceNow) }
                    },
                    onSeek: onSeek,
                    onShowGraph: graphs.map { graphs in { graphs.show(key) } },
                    color: control.kind.isColor ? colorBinding(control, of: effect, c) : nil,
                    menu: menu
                ),
                lane: ParameterLane(
                    marks: control.number.marks, geometry: c.geometry, playhead: c.frameTime, height: EffectsPanelMetrics.rowHeight,
                    onSeek: onSeek,
                    onMove: { from, to in editControl(control.id, of: effect, in: clip) { $0.number.moveKeyframe(at: from, to: to) } },
                    onDelete: { time in editControl(control.id, of: effect, in: clip) { $0.number.removeKeyframe(at: time) } },
                    onEase: { time, preset in editControl(control.id, of: effect, in: clip) { $0.number.applyEase(preset, at: time) } }
                )
            )
            .dropDestination(for: ControlMovePayload.self, action: dropControl)
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
                let rgba = control.values(at: c.sourceNow).map { CGFloat($0) }
                guard rgba.count == 4 else { return CGColor(gray: 1, alpha: 1) }
                return CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
            },
            set: { picked in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let srgb = picked.converted(to: space, intent: .defaultIntent, options: nil),
                      let parts = srgb.components, parts.count >= 4
                else { return }
                let values = parts.prefix(4).map { control.kind.clamped(Double($0)) }
                editControl(control.id, of: effect, in: c.clip) { $0.number.set(ComponentValue(values: values), at: c.sourceNow) }
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
                time: c.sourceNow,
                onEdit: { change in editClip(clip.id) { change(&$0[keyPath: keyPath]) } },
                onSeek: { onSeek(clip.timelineTime(forSourceTime: $0)) },
                onShowGraph: graphs.map { graphs in { graphs.show(key) } }
            )
            .padding(.horizontal, 8),
            lane: ParameterLane(
                marks: value.marks, geometry: c.geometry, playhead: c.frameTime, height: EffectsPanelMetrics.rowHeight,
                onSeek: onSeek,
                onMove: { from, to in editClip(clip.id) { $0[keyPath: keyPath].moveKeyframe(at: from, to: to) } },
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
        EffectClipboard.shared.bundle = project.bundle(ofEffects: [effect.id], fromClip: clip.id, in: timelineID)
    }

    /// Pastes the copied effects below `effect`, or at the end of the stack.
    private func paste(in clip: TimelineClip, below effect: Effect?) {
        guard let bundle = EffectClipboard.shared.bundle else { return }
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

    /// Delete removes the selected control, or else the selected effect;
    /// Command-D duplicates the selected effect.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        // Command-V pastes below the selected effect, or at the end of the
        // selected clip's stack.
        if flags == .command, key == "v", let clip = selectedClip, project.hasEffectStack(clip) || project.playsAudio(clip),
           !EffectClipboard.shared.isEmpty {
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
            if let controlID = state.selectedControlID {
                editEffect(effect.id, in: clip) { $0.removeControl(controlID) }
                state.select(effect: effect.id)
            } else {
                delete(effect, from: clip)
            }
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "d" {
            duplicate(effect, in: clip)
            return true
        }
        return false
    }
}
