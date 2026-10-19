import CoreMedia
import SwiftUI

/// A Sound or Music layer's sound effects, in the inspector's Layer sound
/// group: each one's on switch and name, opened to show its settings (an
/// EQ's graph and bands, fields for the others), and a menu to add one.
/// Settings are set at the playhead in the timeline's time, setting a
/// keyframe there where a setting is animated.
struct LayerSoundEffectsList: View {
    @Binding var project: EditingProject
    let timelineID: UUID
    let layer: TimelineLayer
    /// The playhead on a frame, in the timeline's time.
    let playhead: PlayheadTime

    @State private var open: Set<UUID> = []

    init(project: Binding<EditingProject>, timelineID: UUID, layer: TimelineLayer, playhead: PlayheadTime) {
        _project = project
        self.timelineID = timelineID
        self.layer = layer
        self.playhead = playhead
    }

    /// A list with the playhead at `time`.
    init(project: Binding<EditingProject>, timelineID: UUID, layer: TimelineLayer, time: CMTime) {
        self.init(project: project, timelineID: timelineID, layer: layer, playhead: PlayheadTime(fixed: time))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.close) {
            ForEach(Array(layer.audioEffects.enumerated()), id: \.element.id) { index, effect in
                header(effect, at: index)
                if open.contains(effect.id) {
                    settings(of: effect)
                        .padding(.leading, Design.Space.group)
                        .opacity(effect.enabled ? 1 : 0.5)
                }
            }
            Menu {
                ForEach(EffectKind.allCases.filter(\.isAudio)) { kind in
                    Button(kind.name) {
                        if let id = project.addEffect(kind, toLayer: layer.id, in: timelineID) { open.insert(id) }
                    }
                }
            } label: {
                Label("Add Sound Effect", systemImage: "plus")
            }
            .controlSize(.small)
            .fixedSize()
            .help("Add a sound effect that everything on this layer plays through")
        }
    }

    private func header(_ effect: Effect, at index: Int) -> some View {
        let isOpen = open.contains(effect.id)
        return HStack(spacing: Design.Space.step) {
            Button {
                if isOpen { open.remove(effect.id) } else { open.insert(effect.id) }
            } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Design.textSecondary)
            .accessibilityLabel(isOpen ? "Hide \(effect.displayName)'s settings" : "Show \(effect.displayName)'s settings")
            Toggle(effect.displayName, isOn: Binding(
                get: { effect.enabled },
                set: { value in edit(effect) { $0.enabled = value } }
            ))
            .toggleStyle(.checkbox)
            .opacity(effect.isNoOp ? 0.6 : 1)
            Spacer(minLength: 0)
            Menu {
                Button("Move Up") { project.moveEffect(effect.id, ofLayer: layer.id, in: timelineID, toIndex: index - 1) }
                    .disabled(index == 0)
                Button("Move Down") { project.moveEffect(effect.id, ofLayer: layer.id, in: timelineID, toIndex: index + 1) }
                    .disabled(index == layer.audioEffects.count - 1)
                Button("Reset") { edit(effect) { $0.reset() } }
                Divider()
                Button("Delete", role: .destructive) { project.removeEffect(effect.id, fromLayer: layer.id, in: timelineID) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(effect.displayName) options")
        }
        .font(Design.Typeface.label)
    }

    @ViewBuilder
    private func settings(of effect: Effect) -> some View {
        let onEdit: (ControlKind, (inout EffectControl) -> Void) -> Void = { kind, change in
            edit(effect) { effect in
                if let index = effect.controls.firstIndex(where: { $0.kind == kind }) { change(&effect.controls[index]) }
            }
        }
        if effect.kind == .equalizer {
            // An EQ shows its bands at the playhead, so it is read here, in a
            // view of its own, and not as the list is built.
            PlayheadTimeReader(playhead: playhead) { time in
                EqualizerGraph(effect: effect, time: time, isDimmed: effect.isNoOp, onEdit: onEdit)
                    .frame(height: EqualizerGraph.panelHeight)
                ScrollView(.horizontal) {
                    EqualizerBandStrip(effect: effect, time: time, onEdit: onEdit)
                }
            }
        } else {
            ForEach(effect.controls) { control in
                controlRow(control, onEdit: onEdit)
            }
        }
    }

    /// One control as a name and its fields, or its choices.
    private func controlRow(_ control: EffectControl, onEdit: @escaping (ControlKind, (inout EffectControl) -> Void) -> Void) -> some View {
        let kind = control.kind
        return HStack(spacing: Design.Space.step) {
            Text(kind.name)
                .foregroundStyle(Design.textSecondary)
                .frame(width: 84, alignment: .leading)
            if kind.isChoice {
                Picker(kind.name, selection: Binding(
                    get: { control.choice ?? kind.defaultChoice ?? "" },
                    set: { value in onEdit(kind) { $0.choice = value } }
                )) {
                    ForEach(kind.choiceOptions, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            } else {
                let values = control.values(at: playhead.shown(animated: control.isAnimated))
                ForEach(values.indices, id: \.self) { index in
                    NumericField(
                        value: values[index],
                        unit: kind.unit(ofComponent: index),
                        fractionDigits: kind.dragStep(ofComponent: index) < 0.1 ? 2 : 1,
                        dragStep: kind.dragStep(ofComponent: index),
                        dragRange: kind.range(ofComponent: index),
                        accessibilityName: kind.name
                    ) { value in
                        let at = playhead.now
                        onEdit(kind) { $0.setComponent(index, to: value, at: at) }
                    }
                }
            }
        }
        .font(Design.Typeface.label)
        .opacity(control.enabled ? 1 : 0.5)
    }

    private func edit(_ effect: Effect, _ change: (inout Effect) -> Void) {
        project.editEffect(effect.id, ofLayer: layer.id, in: timelineID, change)
    }
}
