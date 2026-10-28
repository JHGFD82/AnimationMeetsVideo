import CoreMedia
import SwiftUI

/// A control's row in the effects panel: its value, its lane of keyframes,
/// its reset button and its ⋯ menu.
extension EffectsPanel {
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

    /// `movable` gives the row a handle to drag it within the effect by.
    func controlRow(_ control: EffectControl, of effect: Effect, _ c: RowContext, effectDimmed: Bool, movable: Bool = true) -> some View {
        let key = ControlRowKey(
            timelineID: timelineID, clipID: c.clip.id, effect: effect, effectDimmed: effectDimmed,
            isSelected: state.selectedControlID == control.id, showsLanes: showsKeyframeLanes,
            lane: LaneKey(c.geometry), frameSize: c.timeline.frameSize
        )
        return StackRow(key: key) { controlRowContent(control, of: effect, c, effectDimmed: effectDimmed, movable: movable) }
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
        return held.clipAndLayer(clip.id, in: timelineID)?.clip.effect(id: effect.id)?.controls.first(id: control.id)
    }

    @ViewBuilder
    private func controlRowContent(_ control: EffectControl, of effect: Effect, _ c: RowContext, effectDimmed: Bool, movable: Bool) -> some View {
        let clip = c.clip
        let handle = !movable ? AnyView(Color.clear.frame(width: 12)) : AnyView(
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
                    // A curve's numbers are its points, shaped on its effect's
                    // graph, not values with eases to graph.
                    onShowGraph: control.kind.isCurve ? nil : graphs.map { graphs in { graphs.show(key) } },
                    color: control.kind.isColor ? colorBinding(control, of: effect, c) : nil,
                    summary: control.kind.isCurve ? curveSummary(shown, at: c.sourceNow(animated: control.isAnimated)) : nil,
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

    /// What a curve control's row says of it: how many points it has, or
    /// that it changes nothing.
    private func curveSummary(_ control: EffectControl, at time: CMTime) -> String {
        let curve = control.curve(at: time)
        return curve.isIdentity ? "Straight" : "\(curve.points.count) points"
    }

    /// A variable font axis of a Text effect's font, as a control's row is,
    /// listed under the effect's Character section, apart from the font
    /// and its named styles, which are set in the inspector and can't be
    /// keyframed:
    /// its value at the playhead, stopwatch and keyframe buttons, its lane
    /// of keyframes and its graph editor, kept in the effect's
    /// `TextContent.variations` by tag. Reset gives the font's default.
    @ViewBuilder
    func variationRow(_ axis: FontCatalog.Axis, of effect: Effect, _ c: RowContext, effectDimmed: Bool) -> some View {
        let clip = c.clip
        let value = effect.text?.variations.first { $0.axis == axis.tag }?.value ?? AnimatedValue(axis.defaultValue)
        let components = value.asComponents
        let key = ParameterKey(timelineID: timelineID, parameter: .textVariation(axis: axis.tag, clipID: clip.id, effectID: effect.id))
        let edit = { (change: @escaping (inout AnimatedValue<Double>) -> Void) in
            editEffect(effect.id, in: clip) { $0.text?.changeVariation(axis.tag, initial: axis.defaultValue, change) }
        }
        let reset = { editEffect(effect.id, in: clip) { $0.text?.variations.removeAll { $0.axis == axis.tag } } }
        labelled(
            ParameterRow(
                name: axis.name,
                indent: EffectsPanelMetrics.controlIndent - 12,
                components: components.value(at: c.sourceNow(animated: value.isAnimated)).values,
                unit: "",
                dragStep: (axis.maximum - axis.minimum) / 200,
                dragRange: { _ in axis.minimum...axis.maximum },
                isAnimated: value.isAnimated,
                isSelected: false,
                keyframeTimes: value.keyframes.map { clip.timelineTime(forSourceTime: $0.time) },
                playhead: c.frameTime(animated: value.isAnimated),
                dragHandle: AnyView(Color.clear.frame(width: 12)),
                isDimmed: effectDimmed,
                onReset: reset,
                showsReset: { [variations = effect.text?.variations ?? []] in variations.contains { $0.axis == axis.tag } },
                onSelect: { state.select(effect: effect.id) },
                onSetComponent: { _, picked in
                    let at = c.now.sourceNow
                    edit { $0.set(picked.clamped(between: axis.minimum, and: axis.maximum), at: at) }
                },
                onToggleAnimated: {
                    let at = c.now.sourceNow
                    edit { $0.setAnimated(!$0.isAnimated, at: at) }
                },
                onToggleKeyframe: {
                    let at = c.now.sourceNow
                    edit { $0.toggleKeyframe(at: at) }
                },
                onSeek: onSeek,
                onShowGraph: graphs.map { graphs in { graphs.show(key) } },
                menu: { Button("Reset to the Font's Default", action: reset) }
            ),
            lane: ParameterLane(
                marks: components.marks, geometry: c.geometry, playhead: c.frameTime(animated: value.isAnimated),
                height: EffectsPanelMetrics.rowHeight, onSeek: onSeek,
                onMove: { from, to, copy in edit { $0.moveKeyframe(at: from, to: to, copying: copy) } },
                onDelete: { time in edit { $0.removeKeyframe(at: time) } },
                onEase: { time, preset in edit { $0.applyEase(preset, at: time) } }
            )
        )
        .help("The font's \(axis.name.lowercased()), from \(NumericExpression.format(axis.minimum)) to \(NumericExpression.format(axis.maximum))")
    }

    /// A setting some letters of a Text effect have their own of
    /// (`TextRunStyle`), under their run's header, as a control's row is:
    /// its value at the playhead, stopwatch and keyframe buttons, its lane
    /// and its graph editor. The inspector gives letters their own of a
    /// setting; here it is keyframed. Reset gives them the block's back,
    /// which takes the row away.
    @ViewBuilder
    func runRow(_ setting: TextRunSetting, of run: TextRun, in effect: Effect, _ c: RowContext, effectDimmed: Bool) -> some View {
        let clip = c.clip
        let start = run.start
        if let value = run.style.components(of: setting) {
            let key = ParameterKey(
                timelineID: timelineID, parameter: .textRun(setting, start: start, clipID: clip.id, effectID: effect.id)
            )
            let edit = { (change: @escaping (inout AnimatedValue<ComponentValue>) -> Void) in
                editEffect(effect.id, in: clip) { $0.text?.changeRun(startingAt: start) { $0.changeComponents(of: setting, change) } }
            }
            let reset = {
                editEffect(effect.id, in: clip) { effect in
                    effect.text?.changeStyle(in: run.range) { style in
                        if let path = setting.number { style[keyPath: path] = nil }
                        if let path = setting.color { style[keyPath: path] = nil }
                    }
                }
            }
            let range = setting.range
            labelled(
                ParameterRow(
                    name: setting.name,
                    indent: EffectsPanelMetrics.controlIndent - 12,
                    components: value.value(at: c.sourceNow(animated: value.isAnimated)).values,
                    unit: setting.unit,
                    dragRange: { _ in range },
                    isAnimated: value.isAnimated,
                    isSelected: false,
                    keyframeTimes: value.keyframes.map { clip.timelineTime(forSourceTime: $0.time) },
                    playhead: c.frameTime(animated: value.isAnimated),
                    dragHandle: AnyView(Color.clear.frame(width: 12)),
                    isDimmed: effectDimmed,
                    onReset: reset,
                    onSelect: { state.select(effect: effect.id) },
                    onSetComponent: { index, picked in
                        let at = c.now.sourceNow
                        edit { value in
                            var values = value.value(at: at).values
                            guard values.indices.contains(index) else { return }
                            values[index] = picked.clamped(between: range.lowerBound, and: range.upperBound)
                            value.set(ComponentValue(values: values), at: at)
                        }
                    },
                    onToggleAnimated: {
                        let at = c.now.sourceNow
                        edit { $0.setAnimated(!$0.isAnimated, at: at) }
                    },
                    onToggleKeyframe: {
                        let at = c.now.sourceNow
                        edit { $0.toggleKeyframe(at: at) }
                    },
                    onSeek: onSeek,
                    onShowGraph: graphs.map { graphs in { graphs.show(key) } },
                    color: setting.isColor ? runColorBinding(value, at: c, edit: edit) : nil,
                    menu: { Button("Use the Block's \(setting.name)", action: reset) }
                ),
                lane: ParameterLane(
                    marks: value.marks, geometry: c.geometry, playhead: c.frameTime(animated: value.isAnimated),
                    height: EffectsPanelMetrics.rowHeight, onSeek: onSeek,
                    onMove: { from, to, copy in edit { $0.moveKeyframe(at: from, to: to, copying: copy) } },
                    onDelete: { time in edit { $0.removeKeyframe(at: time) } },
                    onEase: { time, preset in edit { $0.applyEase(preset, at: time) } }
                )
            )
            .help("The \(setting.name.lowercased()) of the letters \(effect.text?.quotedLetters(of: run) ?? ""), set apart from the block's")
        }
    }

    /// A styled run's color, picked with a well, set at the playhead.
    private func runColorBinding(
        _ value: AnimatedValue<ComponentValue>, at c: RowContext,
        edit: @escaping (@escaping (inout AnimatedValue<ComponentValue>) -> Void) -> Void
    ) -> Binding<CGColor> {
        Binding(
            get: {
                let rgba = value.value(at: c.sourceNow(animated: value.isAnimated)).values.map { CGFloat($0) }
                guard rgba.count == 4 else { return CGColor(gray: 1, alpha: 1) }
                return CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
            },
            set: { picked in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let srgb = picked.converted(to: space, intent: .defaultIntent, options: nil),
                      let parts = srgb.components, parts.count >= 4
                else { return }
                let values = parts.prefix(4).map { Double($0).clamped(between: 0, and: 1) }
                let at = c.now.sourceNow
                edit { $0.set(ComponentValue(values: values), at: at) }
            }
        )
    }

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
            let held = state?.held?.clipAndLayer(clipID, in: timelineID)?.clip.effect(id: effectID)?.controls.first(id: controlID)
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
}
