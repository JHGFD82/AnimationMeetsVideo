import CoreMedia
import SwiftUI

/// The effects panel's rows for the clip's anchor point and each of its
/// effects: an effect's header and ⋯ menu, its controls in order, and the
/// rows of the clip's own that sit among them.
extension EffectsPanel {
    // MARK: Anchor point

    func anchorRow(_ c: RowContext) -> some View {
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
        .help(clip.source == .graphic
              ? "Where scale and rotation turn about, from the middle of the first shape. It is the top of the stack, so it applies to every step."
              : "Where scale and rotation turn about, from the center of the picture. It is the top of the stack, so it applies to every step.")
    }

    // MARK: Effects

    /// An effect's rows: its header, notes, and its controls under their
    /// sections' headers. A graphic clip's drawing (`isDrawing`) is the
    /// clip's own content rather than an effect: its header has no handle,
    /// checkbox or thumbnail, and its menu neither moves, copies, turns
    /// off nor deletes it.
    @ViewBuilder
    func effectRows(_ effect: Effect, _ c: RowContext, isDrawing: Bool = false) -> some View {
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
            thumbnail: isDrawing ? nil : thumbnails[effect.id].map(ObjectIdentifier.init), summary: summary,
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
                        thumbnail: isDrawing ? nil : thumbnails[effect.id],
                        isDrawing: isDrawing,
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
                        if isDrawing { drawingMenu(effect, in: clip) } else { effectMenu(effect, in: clip) }
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
                controlSections(effect, c, effectDimmed: dimmed)
                if effect.kind.readsAgainst {
                    againstRow(effect, c, effectDimmed: dimmed)
                }
                if effect.kind.takesInput {
                    inputRow(effect, c, effectDimmed: dimmed)
                }
            }
        }
        .selectedRow(state.selectedEffectID == effect.id && state.selectedControlID == nil)
        // A drawing isn't a place in the stack to drop at or move.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(EffectStackLayout.space)) } action: { frame in
            if isDrawing { stackLayout.effects[effect.id] = nil } else { stackLayout.effects[effect.id] = frame }
        }
    }

    /// An effect's controls the panel lists (`Effect.panelSections`): each
    /// section under its header, a Text effect's font axes after its
    /// Character controls. A section with nothing to show has no header.
    @ViewBuilder
    private func controlSections(_ effect: Effect, _ c: RowContext, effectDimmed: Bool) -> some View {
        let axes = effect.kind == .text ? effect.text.map { FontCatalog.axes(of: $0.fontName) } ?? [] : []
        let groups = effect.panelSections()
        // Controls move only where the order is theirs alone: a sectioned
        // effect lists them in its sections' order.
        let movable = effect.kind.sections.isEmpty
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            let groupAxes = group.section?.holdsFontAxes == true ? axes : []
            if let section = group.section, !group.controls.isEmpty || !groupAxes.isEmpty {
                labelled(ControlSectionHeader(name: section.name), lane: emptyLane(c))
            }
            ForEach(group.controls) { control in
                controlRow(control, of: effect, c, effectDimmed: effectDimmed, movable: movable)
            }
            ForEach(groupAxes) { axis in
                variationRow(axis, of: effect, c, effectDimmed: effectDimmed)
            }
        }
        // Letters styled apart, each run under a header of its letters,
        // with the settings it has its own of.
        if effect.kind == .text, let text = effect.text {
            ForEach(text.runs.filter { !$0.style.ownSettings.isEmpty }, id: \.start) { run in
                labelled(ControlSectionHeader(name: "Letters", detail: text.quotedLetters(of: run)), lane: emptyLane(c))
                ForEach(run.style.ownSettings, id: \.self) { setting in
                    runRow(setting, of: run, in: effect, c, effectDimmed: effectDimmed)
                }
            }
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
        let addable = effect.missingControlKinds.filter { effect.kind.panelLists($0) }
        if !addable.isEmpty {
            Menu("Add Control") {
                ForEach(addable) { kind in
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

    /// The ⋯ menu of a graphic clip's drawing: what changes its settings,
    /// not what would treat it as an effect in the stack.
    @ViewBuilder
    private func drawingMenu(_ effect: Effect, in clip: TimelineClip) -> some View {
        Button("Reset") { editEffect(effect.id, in: clip) { $0.reset(in: timeline?.frameSize) } }
            .disabled(effect.controls.allSatisfy { $0.isNoOp && !$0.isAnimated } && effect.controls.count == effect.kind.controlKinds.count)
        let addable = effect.missingControlKinds.filter { effect.kind.panelLists($0) }
        if !addable.isEmpty {
            Menu("Add Control") {
                ForEach(addable) { kind in
                    Button(kind.name) { editEffect(effect.id, in: clip) { $0.addControl(kind) } }
                }
            }
        }
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

    func clipRows<Content: View>(_ c: RowContext, @ViewBuilder content: @escaping () -> Content) -> some View {
        let key = ClipRowsKey(
            timelineID: timelineID, clip: c.clip, layerID: c.layer.id, showsLanes: showsKeyframeLanes,
            lane: LaneKey(c.geometry), frameSize: c.timeline.frameSize,
            playsVideo: project.playsVideo(c.clip), playsAudio: project.playsAudio(c.clip),
            speedBlocked: speedBlockedClipID == c.clip.id
        )
        return StackRow(key: key, content: content).equatable()
    }
}
