import CoreMedia
import Observation
import SwiftUI

/// Which clip a Keyframe Designer shows.
struct KeyframeDesignerKey: Hashable {
    var timelineID: UUID
    var clipID: UUID
}

/// The control a Keyframe Designer is driving, which opening it from an
/// effect's or a control's ⋯ menu sets while it is open.
@MainActor @Observable
final class KeyframeDesignerFocus {
    var target: KeyframingTarget?

    init(target: KeyframingTarget?) {
        self.target = target
    }
}

/// The Keyframe Designer: a floating panel, beside the graph editors, for
/// making a control's keyframes from a method (see
/// docs/keyframing-effects.md, "The Keyframe Designer"). Along the top,
/// the control it drives, any of the clip's; down the left, the methods
/// (None, Audio Keys, Beat Keys, Wiggler, …) and, under the one picked,
/// what it applies to and its settings; filling the right, the control's
/// graph, where every change shows at once, with a time row to drag the
/// playhead along. Audio Keys adds the sound's spectrum and its box above
/// the graph. Picking a method puts a Keyframing effect of that kind in
/// the stack, just above the control's effect; None takes it away, putting
/// the control back as it was, and Bake keeps the keyframes and takes the
/// effect away, with what the control was before. While a method drives
/// the control its keyframes can't be changed by hand, here or anywhere
/// else (`ProjectState.Refusal.drivenKeyframes`). Settings are set at the
/// playhead, as in the effects panel, so a keyframed one gets a keyframe
/// there.
struct KeyframeDesigner: View {
    let hud: KeyframeGraphHUDs
    let key: KeyframeDesignerKey
    let focus: KeyframeDesignerFocus
    let input: GraphInput

    static let sidebarWidth: CGFloat = 290

    var body: some View {
        if let found = hud.project.clipAndLayer(key.clipID, in: key.timelineID), let timeline = hud.project.timeline(id: key.timelineID) {
            let clip = found.clip
            let targets = hud.project.keyframingTargets(in: clip)
            if let target = focus.target.flatMap({ targets.contains($0) ? $0 : nil }) ?? targets.first {
                let driver = hud.project.keyframingEffect(driving: target, in: clip)
                VStack(spacing: 0) {
                    KeyframeDesignerTransport(hud: hud, frameRate: timeline.frameRate)
                    toolbar(target, targets: targets, driver: driver, clip: clip)
                    Divider()
                    HStack(spacing: 0) {
                        ScrollView {
                            KeyframeDesignerSidebar(
                                hud: hud, key: key, target: target, driver: driver, clip: clip, timeline: timeline
                            )
                            .padding(Design.Space.group)
                        }
                        .frame(width: Self.sidebarWidth)
                        .background(Design.Surface.raised.color)
                        Groove(axis: .vertical)
                        GeometryReader { geometry in
                            VStack(spacing: 0) {
                                if let driver, driver.kind == .audioKeys {
                                    LiveSpectrum(hud: hud, effect: driver, clip: clip, timeline: timeline, at: sourceTime(clip, timeline)) { kind, a, b in
                                        editControl(driver.id, kind) { control in
                                            let now = sourceTime(clip, timeline)
                                            control.setComponent(0, to: a, at: now)
                                            control.setComponent(1, to: b, at: now)
                                        }
                                    }
                                    // Leave 200 points for the graph and room for the spectrum's padding.
                                    .frame(height: min(170, max(80, geometry.size.height - 220)))
                                    .padding(Design.Space.step)
                                    Divider()
                                }
                                if let graph = Self.parameterKey(of: target, in: clip, timelineID: key.timelineID) {
                                    KeyframeGraphView(hud: hud, key: graph, input: input, isInDesigner: true)
                                        .id(KeyframingTargetID(target))
                                        .frame(minHeight: 200)
                                }
                            }
                        }
                        .toolEdge(.keyframeDesigner)
                    }
                }
                .frame(minWidth: 700, minHeight: 400)
                .background(Color.black.opacity(0.2))
            } else {
                message("This clip has no controls to keyframe. Add an effect to it first.")
            }
        } else {
            message("This clip is no longer on the timeline.")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Design.Typeface.label)
            .foregroundStyle(Design.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The clip's source time at the parked playhead, held inside the clip.
    private func sourceTime(_ clip: TimelineClip, _ timeline: Timeline) -> CMTime {
        let time = clip.sourceTime(atTimelineTime: timeline.snappedToFrame(hud.playhead))
        return CMTimeMinimum(CMTimeMaximum(time, clip.trimStart), clip.trimEnd)
    }

    // MARK: Toolbar

    /// The control driven, any of the clip's (each named with the method
    /// driving it, if one is), skimming, and Bake.
    private func toolbar(_ target: KeyframingTarget, targets: [KeyframingTarget], driver: Effect?, clip: TimelineClip) -> some View {
        HStack(spacing: Design.Space.step) {
            Text("Control").foregroundStyle(Design.textSecondary)
            Picker("Control", selection: Binding(
                get: { KeyframingTargetID(target).rawValue },
                set: { id in focus.target = KeyframingTargetID(rawValue: id).target }
            )) {
                ForEach(targets, id: \.self) { option in
                    let driving = hud.project.keyframingEffect(driving: option, in: clip)
                    Text(hud.project.name(of: option, in: clip) + (driving.map { " (\($0.kind.name))" } ?? ""))
                        .tag(KeyframingTargetID(option).rawValue)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
            .help("The control whose keyframes are made: any of the clip's effects', or its volume")
            Spacer(minLength: Design.Space.step)
            Button("Bake Keyframes") {
                guard let driver else { return }
                let key = key
                hud.onEdit { $0.bakeKeyframing(driver.id, ofClip: key.clipID, in: key.timelineID) }
            }
            .disabled(driver == nil)
            .help("Keep the keyframes as plain keyframes and take the method away, so they can be edited by hand")
        }
        .font(Design.Typeface.label)
        .controlSize(.small)
        .padding(.horizontal, Design.Space.step)
        .padding(.vertical, Design.Space.close)
    }

    private func editControl(_ effectID: UUID, _ kind: ControlKind, _ change: @escaping (inout EffectControl) -> Void) {
        let key = key
        hud.onEdit { project in
            project.editEffect(effectID, ofClip: key.clipID, in: key.timelineID) { effect in
                effect.changeControl(kind, change)
            }
        }
    }
}

extension KeyframeDesigner {
    /// The graph a target is shown on.
    static func parameterKey(of target: KeyframingTarget, in clip: TimelineClip, timelineID: UUID) -> ParameterKey? {
        switch target {
        case .volume:
            return ParameterKey(timelineID: timelineID, parameter: .clipVolume(clipID: clip.id))
        case .control(let effectID, let controlID):
            guard let control = clip.effect(id: effectID)?.controls.first(id: controlID) else { return nil }
            return ParameterKey(
                timelineID: timelineID, parameter: .control(control.kind, clipID: clip.id, effectID: effectID, controlID: controlID)
            )
        }
    }
}

/// A target as a string, for pickers and menus to tell them apart.
struct KeyframingTargetID: RawRepresentable, Hashable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ target: KeyframingTarget?) {
        switch target {
        case nil: rawValue = "none"
        case .volume?: rawValue = "volume"
        case .control(let effectID, let controlID)?: rawValue = "\(effectID.uuidString)|\(controlID.uuidString)"
        }
    }

    var target: KeyframingTarget? {
        if rawValue == "volume" { return .volume }
        let parts = rawValue.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
        guard parts.count == 2 else { return nil }
        return .control(effectID: parts[0], controlID: parts[1])
    }
}

// MARK: - Sidebar

/// The designer's left side: the methods, then, for the one driving the
/// control, what it applies to and its settings.
private struct KeyframeDesignerSidebar: View {
    let hud: KeyframeGraphHUDs
    let key: KeyframeDesignerKey
    let target: KeyframingTarget
    let driver: Effect?
    let clip: TimelineClip
    let timeline: Timeline

    /// The methods, None first.
    static let methods: [EffectKind?] = [nil] + EffectKind.all.filter(\.isKeyframing)

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.group) {
            VStack(alignment: .leading, spacing: Design.Space.step) {
                header("Method")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(Array(Self.methods.enumerated()), id: \.offset) { _, kind in
                        KeyframeMethodChip(kind: kind, isSelected: driver?.kind == kind) { choose(kind) }
                    }
                }
                .disabled(!hud.project.hasEffectStack(clip))
                Text(hud.project.hasEffectStack(clip)
                     ? Self.blurb(of: driver?.kind)
                     : "A clip with no pictures can't have its keyframes made by a method yet.")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if driver != nil {
                    // Said here before the alert that refuses the edit
                    // does (`DrivenKeyframesWarning`).
                    Text("While it makes them, the keyframes can't be changed by hand. Bake Keyframes to edit them.")
                        .font(Design.Typeface.micro)
                        .foregroundStyle(Design.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let driver, let setup = driver.keyframing {
                if let note = hud.project.keyframingNote(for: driver, in: clip, of: timeline) {
                    Label(note.text, systemImage: note.dims ? "exclamationmark.triangle" : "info.circle")
                        .font(Design.Typeface.micro)
                        .foregroundStyle(note.dims ? Design.statusWarning : Design.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(note.dims ? "Warning: \(note.text)" : note.text)
                }
                if hud.project.keyframingFreshness(of: driver, in: clip, of: timeline) == .outOfDateWithEdits {
                    KeyframingEditsRow(
                        onRegenerate: { edit { $0.regenerateKeyframes(ofEffect: driver.id, onClip: key.clipID, in: key.timelineID) } },
                        onKeepEdits: { edit { $0.keepKeyframingEdits(driver.id, ofClip: key.clipID, in: key.timelineID) } }
                    )
                    .padding(.leading, -EffectsPanelMetrics.controlIndent)
                }
                VStack(alignment: .leading, spacing: Design.Space.step) {
                    header("Applies To")
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        setupRows(driver, setup)
                    }
                }
                if !driver.controls.isEmpty {
                    VStack(alignment: .leading, spacing: Design.Space.step) {
                        header("Settings")
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                            ForEach(driver.controls) { control in
                                GridRow {
                                    Text(control.kind.name)
                                        .foregroundStyle(control.enabled ? Design.textSecondary : Design.textTertiary)
                                        .gridColumnAlignment(.trailing)
                                        .accessibilityHidden(true)
                                    KeyframingSettingField(control: control, at: sourceTime) { change in
                                        editEffect(driver.id) { $0.changeControl(control.kind, change) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .font(Design.Typeface.label)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ name: String) -> some View {
        Text(name)
            .font(Design.Typeface.groupTitle)
            .foregroundStyle(Design.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    /// The clip's source time at the parked playhead, held inside the clip.
    private var sourceTime: CMTime {
        let time = clip.sourceTime(atTimelineTime: timeline.snappedToFrame(hud.playhead))
        return CMTimeMinimum(CMTimeMaximum(time, clip.trimStart), clip.trimEnd)
    }

    /// What each method does, under the methods.
    static func blurb(of kind: EffectKind?) -> String {
        switch kind {
        case nil: "Keyframes set by hand. Pick a method to make them instead; picking None again puts them back."
        case .audioKeys?: "Follows how loud a range of frequencies is in a sound: drag the box on the spectrum."
        case .beatKeys?: "A pulse, step or ramp on each beat of a Sound or Music layer's beats."
        case .wiggler?: "Random, organic movement around the control's value."
        case .oscillator?: "A regular wave: sine, triangle, square or sawtooth."
        case .smoother?: "Smooths the control's own keyframes, and thins them."
        case .looper?: "Repeats the control's own keyframes past their end, or before their start."
        case .timeStep?: "Holds each value for a number of frames, for a stop-motion look."
        case .overshoot?: "Adds a spring's bounce after each of the control's keyframes."
        default: kind?.name ?? ""
        }
    }

    // MARK: Applies To

    @ViewBuilder
    private func setupRows(_ driver: Effect, _ setup: KeyframingSetup) -> some View {
        if let names = componentNames, names.count > 1 {
            choiceRow(
                "Component", options: [("all", "All")] + names.enumerated().map { (String($0.offset), $0.element) },
                selected: setup.component.map(String.init) ?? "all", help: "Which of the control's values it writes to"
            ) { choice, setup in setup.component = Int(choice) }
        }
        if !driver.kind.reshapesTarget {
            choiceRow(
                "Combine", options: KeyframingCombine.allCases.map { ($0.rawValue, $0.name) }, selected: setup.combine.rawValue,
                help: "How what it makes meets the control's own value: added to it, scaling it as a percent, or in its place"
            ) { choice, setup in setup.combine = KeyframingCombine(rawValue: choice) ?? .add }
        }
        if driver.kind == .audioKeys {
            choiceRow(
                "Listen To", options: hud.project.audioSourceOptions(current: setup.audioSource, in: timeline),
                selected: setup.audioSource.optionID,
                help: "The sound it follows: the whole mix, one Sound or Music layer, or one clip, as heard"
            ) { choice, setup in setup.audioSource = AudioKeysSource(optionID: choice) }
        }
        if driver.kind == .beatKeys {
            choiceRow(
                "Beats From", options: hud.project.beatLayerOptions(current: setup.beatLayer, in: timeline),
                selected: setup.beatLayer?.uuidString ?? "none", help: "The Sound or Music layer whose beats it follows"
            ) { choice, setup in setup.beatLayer = UUID(uuidString: choice) }
        }
        GridRow {
            Text("Range")
                .foregroundStyle(Design.textSecondary)
                .gridColumnAlignment(.trailing)
                .accessibilityHidden(true)
            rangeMenu(setup)
        }
    }

    private var componentNames: [String]? {
        switch target {
        case .volume: ["Level"]
        case .control(let effectID, let controlID): clip.effect(id: effectID)?.controls.first(id: controlID)?.kind.componentNames
        }
    }

    private func choiceRow(
        _ name: String, options: [(id: String, name: String)], selected: String, help: String,
        choose: @escaping (String, inout KeyframingSetup) -> Void
    ) -> some View {
        GridRow {
            Text(name)
                .foregroundStyle(Design.textSecondary)
                .gridColumnAlignment(.trailing)
                .accessibilityHidden(true)
            Picker(name, selection: Binding(get: { selected }, set: { choice in editSetup { choose(choice, &$0) } })) {
                ForEach(options, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 170, alignment: .leading)
            .help(help)
        }
    }

    /// Where it writes, from the playhead: the whole clip, or a stretch of
    /// it; the control keeps its own keyframes outside.
    private func rangeMenu(_ setup: KeyframingSetup) -> some View {
        let label: String = {
            guard let range = setup.range else { return "Whole Clip" }
            let start = clip.timelineTime(forSourceTime: range.start), end = clip.timelineTime(forSourceTime: range.end)
            return "\(CMTimeMinimum(start, end).timecode(frameRate: timeline.frameRate)) – \(CMTimeMaximum(start, end).timecode(frameRate: timeline.frameRate))"
        }()
        let now = clip.sourceTime(atTimelineTime: timeline.snappedToFrame(hud.playhead))
        let inClip = now >= clip.trimStart && now <= clip.trimEnd
        return Menu(label) {
            Button("Start at Playhead") { editSetup { $0.setRange(start: now, in: clip) } }
                .disabled(!inClip)
            Button("End at Playhead") { editSetup { $0.setRange(end: now, in: clip) } }
                .disabled(!inClip)
            Button("Whole Clip") { editSetup { $0.range = nil } }
                .disabled(setup.range == nil)
        }
        .fixedSize()
        .help("Where it writes keyframes; the control keeps its own outside")
        .accessibilityLabel("Range")
        .accessibilityValue(label)
    }

    // MARK: Editing

    private func choose(_ kind: EffectKind?) {
        let key = key, target = target
        hud.onEdit { $0.setKeyframing(kind, driving: target, onClip: key.clipID, in: key.timelineID) }
        AccessibilityNotification.Announcement(kind.map { "\($0.name) drives it" } ?? "Keyframes set by hand").post()
    }

    private func edit(_ change: @escaping (inout EditingProject) -> Void) {
        hud.onEdit(change)
    }

    private func editEffect(_ effectID: UUID, _ change: @escaping (inout Effect) -> Void) {
        let key = key
        hud.onEdit { $0.editEffect(effectID, ofClip: key.clipID, in: key.timelineID, change) }
    }

    private func editSetup(_ change: @escaping (inout KeyframingSetup) -> Void) {
        guard let driver else { return }
        editEffect(driver.id) { effect in
            if effect.keyframing != nil { change(&effect.keyframing!) }
        }
    }
}

/// A method in the designer: a chip with its glyph and name, lit while it
/// drives the control.
private struct KeyframeMethodChip: View {
    let kind: EffectKind?
    let isSelected: Bool
    let onChoose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onChoose) {
            HStack(spacing: 6) {
                Image(systemName: kind?.systemImage ?? "hand.point.up.left")
                    .foregroundStyle(isSelected ? Design.accent : isHovering ? Design.textPrimary : Design.textSecondary)
                    .frame(width: 16)
                Text(kind?.name ?? "None")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .beveledChip(fill: isSelected ? Design.accent.opacity(0.25) : isHovering ? Design.Surface.floating.color : Design.Surface.overlay.color)
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.chip)
                    .strokeBorder(Design.accent, lineWidth: 1)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(KeyframeDesignerSidebar.blurb(of: kind))
        .accessibilityLabel(kind?.name ?? "None")
        .accessibilityHint(KeyframeDesignerSidebar.blurb(of: kind))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Settings

/// One setting of a Keyframing effect as a field (or a pop-up for a
/// choice), set at `time`: a keyframed one gets a keyframe there.
struct KeyframingSettingField: View {
    let control: EffectControl
    let at: CMTime
    let onChange: (@escaping (inout EffectControl) -> Void) -> Void

    var body: some View {
        if control.kind.isChoice {
            Picker(control.kind.name, selection: Binding(
                get: { control.choice ?? control.kind.defaultChoice ?? "" },
                set: { choice in onChange { $0.choice = choice } }
            )) {
                ForEach(control.kind.choiceOptions, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 140, alignment: .leading)
        } else {
            let values = control.values(at: at)
            let names = control.kind.componentNames
            let time = at
            HStack(spacing: 4) {
                ForEach(values.indices, id: \.self) { index in
                    if values.count > 1 {
                        Text(names.indices.contains(index) ? names[index] : "")
                            .font(Design.Typeface.micro)
                            .foregroundStyle(Design.textTertiary)
                            .accessibilityHidden(true)
                    }
                    NumericField(
                        value: values[index], unit: control.kind.unit, fractionDigits: control.kind.dragStep < 1 ? 2 : 1,
                        dragStep: control.kind.dragStep, dragRange: control.kind.range,
                        accessibilityName: values.count > 1 && names.indices.contains(index) ? "\(control.kind.name) \(names[index])" : control.kind.name
                    ) { newValue in
                        onChange { $0.setComponent(index, to: newValue, at: time) }
                    }
                }
                if control.isAnimated {
                    Image(systemName: "stopwatch.fill")
                        .font(Design.Typeface.glyphTiny)
                        .foregroundStyle(Design.accent)
                        .help("Keyframed: a change sets a keyframe at the playhead")
                        .accessibilityLabel("Keyframed")
                }
            }
        }
    }
}

// MARK: - Spectrum

/// The spectrum and box, at the player's time while it plays and at the
/// playhead otherwise. Only this view follows the player, so playing
/// redraws the spectrum and nothing else.
private struct LiveSpectrum: View {
    let hud: KeyframeGraphHUDs
    let effect: Effect
    let clip: TimelineClip
    let timeline: Timeline
    /// The source time settings are read at.
    let at: CMTime
    let onSet: (ControlKind, Double, Double) -> Void

    var body: some View {
        let playing = hud.playback?.isPlaying == true
        let time = playing ? hud.playback?.currentTime ?? hud.playhead : hud.playhead
        let source = effect.keyframing?.audioSource
        let bands = source.flatMap { hud.project.heardBands($0, in: timeline, at: [time])?.first }
        let frequencies = effect.control(.frequencyRange)?.values(at: at) ?? ControlKind.frequencyRange.defaultValues
        let levels = effect.control(.levelRange)?.values(at: at) ?? ControlKind.levelRange.defaultValues
        AudioKeysGraph(
            bands: bands,
            frequencies: (frequencies[0], frequencies[1]),
            levels: (levels[0], levels[1]),
            level: bands.map { AudioKeysMath.level(of: $0, from: frequencies[0], to: frequencies[1]) },
            isDimmed: !effect.enabled,
            onSetFrequencies: { onSet(.frequencyRange, $0, $1) },
            onSetLevels: { onSet(.levelRange, $0, $1) }
        )
    }
}

// MARK: - Sources

extension AudioKeysSource {
    /// How a picker tells the sources apart.
    var optionID: String {
        switch self {
        case .mix: "mix"
        case .layer(let id): "layer|\(id.uuidString)"
        case .clip(let id): "clip|\(id.uuidString)"
        }
    }

    init?(optionID: String) {
        if optionID == "mix" {
            self = .mix
            return
        }
        let parts = optionID.split(separator: "|")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        self = parts[0] == "layer" ? .layer(id) : .clip(id)
    }
}

extension Optional where Wrapped == AudioKeysSource {
    var optionID: String { self?.optionID ?? "none" }
}

extension EditingProject {
    /// What an Audio Keys effect can listen to in a timeline, for a picker:
    /// nothing, the whole mix, each Sound and Music layer and each clip
    /// with sound, and "Unavailable" for `current` when it is gone.
    func audioSourceOptions(current: AudioKeysSource?, in timeline: Timeline) -> [(id: String, name: String)] {
        var options: [(id: String, name: String)] = [("none", "Nothing"), ("mix", "Whole Mix")]
        options += timeline.layers.filter(\.kind.isAudio).map {
            (AudioKeysSource.layer($0.id).optionID, displayName(of: $0, in: timeline))
        }
        options += timeline.layers.flatMap(\.clips).filter { playsAudio($0) }.map {
            (AudioKeysSource.clip($0.id).optionID, clipName($0.id, in: timeline.id))
        }
        if !options.contains(where: { $0.id == current.optionID }) { options.append((current.optionID, "Unavailable")) }
        return options
    }

    /// The layers Beat Keys can follow, for a picker: none, each Sound and
    /// Music layer, and "Unavailable" for `current` when it is gone.
    func beatLayerOptions(current: UUID?, in timeline: Timeline) -> [(id: String, name: String)] {
        let layers = timeline.layers.filter(\.kind.isAudio)
        var options: [(id: String, name: String)] = [("none", "None")]
        options += layers.map { ($0.id.uuidString, displayName(of: $0, in: timeline)) }
        if let current, !layers.contains(where: { $0.id == current }) {
            options.append((current.uuidString, "Unavailable"))
        }
        return options
    }
}
