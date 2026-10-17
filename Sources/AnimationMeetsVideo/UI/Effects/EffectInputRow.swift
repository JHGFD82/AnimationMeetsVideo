import CoreMedia
import SwiftUI

/// The row under an effect that takes a picture (a matte): a zone to drop
/// footage or a timeline from the browser on, and, once there is one, where
/// in it the clip starts and whether it loops. See docs/effects.md, "Inputs".
extension EffectsPanel {
    func inputRow(_ effect: Effect, _ c: RowContext, effectDimmed: Bool) -> some View {
        let clip = c.clip
        return VStack(spacing: 0) {
            labelled(inputZone(effect, clip: clip).opacity(effectDimmed ? 0.45 : 1), lane: emptyLane(c))
            if let input = effect.input {
                labelled(inputOptions(input, effect: effect, clip: clip).opacity(effectDimmed ? 0.45 : 1), lane: emptyLane(c))
            }
        }
        .dropDestination(for: SceneDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            return setInput(EffectInput(source: .asset(payload.assetID)), on: effect, in: clip)
        }
        .dropDestination(for: TimelineDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            return setInput(EffectInput(source: .timeline(payload.timelineID)), on: effect, in: clip)
        }
    }

    private func setInput(_ input: EffectInput?, on effect: Effect, in clip: TimelineClip) -> Bool {
        var input = input
        // A new picture keeps the offset and looping already chosen.
        if var next = input, let old = effect.input {
            next.offset = old.offset
            next.loops = old.loops
            input = next
        }
        return project.setInput(input, ofEffect: effect.id, onClip: clip.id, in: timelineID)
    }

    private func inputZone(_ effect: Effect, clip: TimelineClip) -> some View {
        let input = effect.input
        let missing = input.map { project.isMissing($0) } ?? false
        return HStack(spacing: 4) {
            Color.clear.frame(width: EffectsPanelMetrics.controlIndent - 12)
            Image(systemName: input == nil ? "square.dashed" : (missing ? "exclamationmark.triangle" : "film"))
                .foregroundStyle(missing ? Design.statusWarning : Design.textTertiary)
            Text(inputTitle(input, missing: missing))
                .foregroundStyle(input == nil ? Design.textTertiary : Design.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            if input != nil {
                Button {
                    _ = project.setInput(nil, ofEffect: effect.id, onClip: clip.id, in: timelineID)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Design.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Remove the input")
            }
        }
        .font(Design.Typeface.label)
        .padding(.horizontal, 4)
        .frame(height: EffectsPanelMetrics.rowHeight)
        .help("Drag footage or a timeline from the browser here")
    }

    private func inputTitle(_ input: EffectInput?, missing: Bool) -> String {
        guard let input else { return "Drop footage or a timeline here" }
        let name = project.name(of: input) ?? "Missing"
        return missing ? "\(name) (missing)" : name
    }

    private func inputOptions(_ input: EffectInput, effect: Effect, clip: TimelineClip) -> some View {
        func edit(_ change: @escaping (inout EffectInput) -> Void) {
            project.editEffect(effect.id, ofClip: clip.id, in: timelineID) { effect in
                guard var input = effect.input else { return }
                change(&input)
                effect.input = input
            }
        }
        return HStack(spacing: 4) {
            Color.clear.frame(width: EffectsPanelMetrics.controlIndent - 12)
            Text("Offset")
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.textTertiary)
            NumericField(
                value: input.offset.seconds, unit: " s", fractionDigits: 2, dragStep: 0.05, dragRange: 0...86_400
            ) { seconds in
                edit { $0.offset = CMTime(seconds: max(seconds, 0), preferredTimescale: 6000) }
            }
            Toggle("Loop", isOn: Binding(get: { input.loops }, set: { value in edit { $0.loops = value } }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Play the input again from its start when it ends, instead of holding its last frame")
            Spacer(minLength: 2)
        }
        .font(Design.Typeface.label)
        .padding(.horizontal, 4)
        .frame(height: EffectsPanelMetrics.rowHeight)
    }
}
