import CoreMedia
import SwiftUI

/// Which Audio Keys effect an editor shows.
struct AudioKeysEditorKey: Hashable {
    var timelineID: UUID
    var clipID: UUID
    var effectID: UUID
}

/// An Audio Keys effect's editor, in a floating panel of its own opened
/// from the effects panel: what it listens to and what it drives, Bake,
/// the spectrum with its box filling the panel, and every setting as
/// fields under it. The spectrum is the sound at the playhead, and moves
/// with the sound while the timeline plays; the line across the box is how
/// loud its range is now. Settings are set at the playhead, as in the
/// effects panel, so a keyframed one gets a keyframe there.
struct AudioKeysEditor: View {
    let hud: KeyframeGraphHUDs
    let key: AudioKeysEditorKey

    var body: some View {
        if let found = hud.project.clipAndLayer(key.clipID, in: key.timelineID),
           let timeline = hud.project.timeline(id: key.timelineID),
           let effect = found.clip.effect(id: key.effectID), let setup = effect.keyframing {
            let clip = found.clip
            let now = sourceTime(clip, timeline)
            VStack(spacing: 0) {
                toolbar(effect, setup, clip: clip, timeline: timeline)
                Divider()
                LiveSpectrum(hud: hud, effect: effect, clip: clip, timeline: timeline, at: now) { kind, a, b in
                    set(kind, [a, b], at: now)
                }
                .padding(Design.Space.step)
                Divider()
                settings(effect, at: now)
            }
            .background(Color.black.opacity(0.2))
        } else {
            Text("This effect is no longer on the timeline.")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The clip's source time at the parked playhead, held inside the clip.
    private func sourceTime(_ clip: TimelineClip, _ timeline: Timeline) -> CMTime {
        let time = clip.sourceTime(atTimelineTime: timeline.snappedToFrame(hud.playhead))
        return CMTimeMinimum(CMTimeMaximum(time, clip.trimStart), clip.trimEnd)
    }

    // MARK: Toolbar

    private func toolbar(_ effect: Effect, _ setup: KeyframingSetup, clip: TimelineClip, timeline: Timeline) -> some View {
        HStack(spacing: Design.Space.step) {
            Text("Listen To").foregroundStyle(Design.textSecondary)
            Picker("Listen To", selection: Binding(
                get: { setup.audioSource.optionID },
                set: { id in editSetup { $0.audioSource = AudioKeysSource(optionID: id) } }
            )) {
                ForEach(hud.project.audioSourceOptions(current: setup.audioSource, in: timeline), id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            Text("Driving \(setup.target.map { hud.project.name(of: $0, in: clip) } ?? "nothing")")
                .foregroundStyle(Design.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Design.Space.step)
            Button("Bake Keyframes") {
                let key = key
                hud.onEdit { $0.bakeKeyframing(key.effectID, ofClip: key.clipID, in: key.timelineID) }
            }
            .help("Remove the effect and keep its keyframes as plain keyframes")
        }
        .font(Design.Typeface.label)
        .controlSize(.small)
        .padding(.horizontal, Design.Space.step)
        .padding(.vertical, Design.Space.close)
    }

    // MARK: Settings

    /// Two columns of the effect's settings, each a name and its fields.
    private func settings(_ effect: Effect, at time: CMTime) -> some View {
        let controls = effect.controls
        let half = (controls.count + 1) / 2
        return HStack(alignment: .top, spacing: Design.Space.group) {
            ForEach([Array(controls.prefix(half)), Array(controls.dropFirst(half))], id: \.first?.id) { column in
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(column) { control in
                        GridRow {
                            Text(control.kind.name)
                                .foregroundStyle(control.enabled ? Design.textSecondary : Design.textTertiary)
                                .gridColumnAlignment(.trailing)
                            field(control, at: time)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(Design.Typeface.label)
        .controlSize(.small)
        .padding(Design.Space.step)
    }

    @ViewBuilder
    private func field(_ control: EffectControl, at time: CMTime) -> some View {
        if control.kind.isChoice {
            Picker(control.kind.name, selection: Binding(
                get: { control.choice ?? control.kind.defaultChoice ?? "" },
                set: { choice in editControl(control.kind) { $0.choice = choice } }
            )) {
                ForEach(control.kind.choiceOptions, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        } else {
            let values = control.values(at: time)
            let names = control.kind.componentNames
            HStack(spacing: 4) {
                ForEach(values.indices, id: \.self) { index in
                    if values.count > 1 {
                        Text(names.indices.contains(index) ? names[index] : "")
                            .font(Design.Typeface.micro)
                            .foregroundStyle(Design.textTertiary)
                    }
                    NumericField(
                        value: values[index], unit: control.kind.unit, fractionDigits: control.kind.dragStep < 1 ? 2 : 1,
                        dragStep: control.kind.dragStep, dragRange: control.kind.range
                    ) { newValue in
                        editControl(control.kind) { $0.setComponent(index, to: newValue, at: time) }
                    }
                    .accessibilityLabel(values.count > 1 && names.indices.contains(index) ? "\(control.kind.name) \(names[index])" : control.kind.name)
                }
                if control.isAnimated {
                    Image(systemName: "stopwatch.fill")
                        .font(Design.Typeface.glyphTiny)
                        .foregroundStyle(Design.accent)
                        .help("Keyframed: a change sets a keyframe at the playhead")
                }
            }
        }
    }

    // MARK: Editing

    private func set(_ kind: ControlKind, _ values: [Double], at time: CMTime) {
        editControl(kind) { control in
            for (index, value) in values.enumerated() { control.setComponent(index, to: value, at: time) }
        }
    }

    private func editControl(_ kind: ControlKind, _ change: @escaping (inout EffectControl) -> Void) {
        let key = key
        hud.onEdit { project in
            project.editEffect(key.effectID, ofClip: key.clipID, in: key.timelineID) { effect in
                if let index = effect.controls.firstIndex(where: { $0.kind == kind }) { change(&effect.controls[index]) }
            }
        }
    }

    private func editSetup(_ change: @escaping (inout KeyframingSetup) -> Void) {
        let key = key
        hud.onEdit { project in
            project.editEffect(key.effectID, ofClip: key.clipID, in: key.timelineID) { effect in
                if effect.keyframing != nil { change(&effect.keyframing!) }
            }
        }
    }
}

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
}
