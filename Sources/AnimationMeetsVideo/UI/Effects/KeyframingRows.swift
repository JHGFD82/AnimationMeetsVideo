import CoreMedia
import SwiftUI

/// A Keyframing effect's rows above its settings: what it writes to, which
/// component, how it combines and, for Beat Keys, whose beats; and its
/// part of the ⋯ menu (see docs/keyframing-effects.md).
extension EffectsPanel {
    @ViewBuilder
    func keyframingRows(_ effect: Effect, _ c: RowContext, effectDimmed: Bool) -> some View {
        if let setup = effect.keyframing {
            besideLane(keyframingActions(effect, c))
            if project.keyframingFreshness(of: effect, in: c.clip, of: c.timeline) == .outOfDateWithEdits {
                besideLane(KeyframingEditsRow(
                    onRegenerate: { project.regenerateKeyframes(ofEffect: effect.id, onClip: c.clip.id, in: timelineID) },
                    onKeepEdits: { project.keepKeyframingEdits(effect.id, ofClip: c.clip.id, in: timelineID) }
                ))
            }
            keyframingChoice(
                "Target", effect, c, dimmed: effectDimmed, options: targetOptions(effect, c), selected: targetID(setup.target),
                help: "The control it writes keyframes to"
            ) { choice, setup in
                setup.target = Self.target(from: choice)
                setup.component = nil
            }
            if let target = setup.target, let names = componentNames(of: target, in: c.clip), names.count > 1 {
                keyframingChoice(
                    "Component", effect, c, dimmed: effectDimmed,
                    options: [("all", "All")] + names.enumerated().map { (String($0.offset), $0.element) },
                    selected: setup.component.map(String.init) ?? "all",
                    help: "Which of the target's values it writes to"
                ) { choice, setup in
                    setup.component = Int(choice)
                }
            }
            if !effect.kind.reshapesTarget {
                keyframingChoice(
                    "Combine", effect, c, dimmed: effectDimmed,
                    options: KeyframingCombine.allCases.map { ($0.rawValue, $0.name) }, selected: setup.combine.rawValue,
                    help: "How what it makes meets the target's own value: added to it, scaling it as a percent, or in its place"
                ) { choice, setup in
                    setup.combine = KeyframingCombine(rawValue: choice) ?? .add
                }
            }
            if effect.kind == .audioKeys {
                keyframingChoice(
                    "Listen To", effect, c, dimmed: effectDimmed,
                    options: project.audioSourceOptions(current: setup.audioSource, in: c.timeline),
                    selected: setup.audioSource.optionID,
                    help: "The sound it follows: the whole mix, one Sound or Music layer, or one clip, as heard"
                ) { choice, setup in
                    setup.audioSource = AudioKeysSource(optionID: choice)
                }
            }
            if effect.kind == .beatKeys {
                keyframingChoice(
                    "Beats From", effect, c, dimmed: effectDimmed, options: beatLayerOptions(setup, c),
                    selected: setup.beatLayer?.uuidString ?? "none",
                    help: "The Sound or Music layer whose beat map it follows"
                ) { choice, setup in
                    setup.beatLayer = UUID(uuidString: choice)
                }
            }
            if let range = setup.range {
                let start = c.clip.timelineTime(forSourceTime: range.start)
                let end = c.clip.timelineTime(forSourceTime: range.end)
                besideLane(EffectNoteRow(note: EffectNote(
                    text: "Writes from \(CMTimeMinimum(start, end).formatted) to \(CMTimeMaximum(start, end).formatted); keyframes outside are kept.",
                    dims: false
                )))
            }
        }
    }

    /// The ⋯ menu's items for a Keyframing effect.
    @ViewBuilder
    func keyframingMenu(_ effect: Effect, _ clip: TimelineClip) -> some View {
        let now = clip.sourceTime(atTimelineTime: timeline.map { $0.snappedToFrame(playheadTime) } ?? playheadTime)
        let inClip = now >= clip.trimStart && now <= clip.trimEnd
        Button("Bake Keyframes") {
            project.bakeKeyframing(effect.id, ofClip: clip.id, in: timelineID)
            if state.selectedEffectID == effect.id { state.clear() }
        }
        .help("Remove the effect and keep its keyframes as plain keyframes")
        Menu("Range") {
            Button("Start at Playhead") { editSetup(effect, clip) { $0.setRange(start: now, in: clip) } }
                .disabled(!inClip)
            Button("End at Playhead") { editSetup(effect, clip) { $0.setRange(end: now, in: clip) } }
                .disabled(!inClip)
            Button("Whole Clip") { editSetup(effect, clip) { $0.range = nil } }
                .disabled(effect.keyframing?.range == nil)
        }
    }

    // MARK: Rows

    /// Bake, which is too important to sit only in the ⋯ menu, and for
    /// Audio Keys the button that opens its spectrum and box. Drawing the
    /// spectrum here for every effect would cost too much to keep up.
    private func keyframingActions(_ effect: Effect, _ c: RowContext) -> some View {
        HStack(spacing: 6) {
            Button("Bake Keyframes") {
                project.bakeKeyframing(effect.id, ofClip: c.clip.id, in: timelineID)
                if state.selectedEffectID == effect.id { state.clear() }
            }
            .help("Remove the effect and keep its keyframes as plain keyframes")
            if effect.kind == .audioKeys, let graphs {
                Button {
                    graphs.showAudioKeys(AudioKeysEditorKey(timelineID: timelineID, clipID: c.clip.id, effectID: effect.id))
                } label: {
                    Label("Spectrum…", systemImage: "waveform.badge.magnifyingglass")
                }
                .help("Open the spectrum to drag the box, adjust every setting and watch the sound as it plays")
            }
            Spacer(minLength: 0)
        }
        .font(Design.Typeface.label)
        .controlSize(.small)
        .padding(.leading, EffectsPanelMetrics.controlIndent)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
    }

    private func keyframingChoice(
        _ name: String, _ effect: Effect, _ c: RowContext, dimmed: Bool, options: [(id: String, name: String)], selected: String,
        help: String, choose: @escaping (String, inout KeyframingSetup) -> Void
    ) -> some View {
        labelled(
            ChoiceRow(
                name: name,
                indent: EffectsPanelMetrics.controlIndent - 12,
                options: options,
                selected: selected,
                isSelected: false,
                dragHandle: nil,
                showsMenu: false,
                isDimmed: dimmed,
                onSelect: {},
                onChoose: { choice in editSetup(effect, c.clip) { choose(choice, &$0) } },
                menu: { EmptyView() }
            ),
            lane: emptyLane(c)
        )
        .help(help)
    }

    private func editSetup(_ effect: Effect, _ clip: TimelineClip, _ change: @escaping (inout KeyframingSetup) -> Void) {
        project.editEffect(effect.id, ofClip: clip.id, in: timelineID) { effect in
            if effect.keyframing != nil { change(&effect.keyframing!) }
        }
    }

    // MARK: Options

    private func targetOptions(_ effect: Effect, _ c: RowContext) -> [(id: String, name: String)] {
        let index = c.clip.effects.index(of: effect.id) ?? 0
        let targets = project.keyframingTargets(forEffectAt: index, in: c.clip)
        var options: [(id: String, name: String)] = [("none", "None")]
        options += targets.map { (targetID($0), project.name(of: $0, in: c.clip)) }
        // One that is gone, or above it now, can't be written to.
        if let target = effect.keyframing?.target, !targets.contains(target) {
            options.append((targetID(target), "Unavailable"))
        }
        return options
    }

    private func beatLayerOptions(_ setup: KeyframingSetup, _ c: RowContext) -> [(id: String, name: String)] {
        let layers = c.timeline.layers.filter(\.kind.isAudio)
        var options: [(id: String, name: String)] = [("none", "None")]
        options += layers.map { ($0.id.uuidString, project.displayName(of: $0, in: c.timeline)) }
        if let id = setup.beatLayer, !layers.contains(where: { $0.id == id }) {
            options.append((id.uuidString, "Unavailable"))
        }
        return options
    }

    private func componentNames(of target: KeyframingTarget, in clip: TimelineClip) -> [String]? {
        switch target {
        case .volume: ["Level"]
        case .control(let effectID, let controlID):
            clip.effect(id: effectID)?.controls.first { $0.id == controlID }?.kind.componentNames
        }
    }

    private func targetID(_ target: KeyframingTarget?) -> String {
        switch target {
        case nil: "none"
        case .volume?: "volume"
        case .control(let effectID, let controlID)?: "\(effectID.uuidString)|\(controlID.uuidString)"
        }
    }

    private static func target(from id: String) -> KeyframingTarget? {
        if id == "volume" { return .volume }
        let parts = id.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
        guard parts.count == 2 else { return nil }
        return .control(effectID: parts[0], controlID: parts[1])
    }
}
