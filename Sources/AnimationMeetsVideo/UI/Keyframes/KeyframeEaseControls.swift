import CoreMedia
import SwiftUI

/// The keyboard and VoiceOver equivalent of shaping either bezier handle.
/// Each side can be added, removed or adjusted independently; held
/// stretches have no handle, just as on the graph.
struct KeyframeEaseControls: View {
    let hud: KeyframeGraphHUDs
    let key: ParameterKey
    let time: CMTime

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.group) {
            Text("Ease Handles")
                .font(Design.Typeface.groupTitle)
                .accessibilityAddTraits(.isHeader)
            if let value = hud.project.components(of: key),
               let index = value.keyframes.firstIndex(where: { $0.time == time }) {
                let frame = value.keyframes[index]
                side("Ease In", ease: frame.easeIn,
                     available: index > 0 && !value.keyframes[index - 1].hold, outgoing: false)
                Divider()
                side("Ease Out", ease: frame.easeOut,
                     available: index + 1 < value.keyframes.count && !frame.hold, outgoing: true)
                Text("Each side changes independently. Speed is a percent of the steady speed between keyframes.")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This keyframe is no longer present.")
            }
        }
        .font(Design.Typeface.label)
        .controlSize(.small)
        .padding(Design.Space.group)
        .frame(width: 300)
    }

    private func side(_ name: String, ease: KeyframeEase?, available: Bool, outgoing: Bool) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            Toggle(name, isOn: Binding(
                get: { ease != nil },
                set: { set($0 ? .easy : nil, outgoing: outgoing) }
            ))
            .disabled(!available)
            if !available {
                Text("No curve on this side: it is held or has no neighboring keyframe.")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let ease {
                HStack(spacing: Design.Space.step) {
                    Text("Reach")
                    HeldSlider(value: ease.influence, range: KeyframeEase.influenceRange) { reach in
                        set(KeyframeEase(influence: reach, speed: ease.speed), outgoing: outgoing)
                    }
                    .accessibilityLabel("\(name) reach")
                    .accessibilityValue("\(Int((ease.influence * 100).rounded())) percent")
                    Text("\(Int((ease.influence * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                HStack(spacing: Design.Space.step) {
                    Text("Speed")
                    EaseSpeedField(value: ease.speed * 100) { speed in
                        set(KeyframeEase(influence: ease.influence, speed: speed / 100), outgoing: outgoing)
                    }
                    .accessibilityLabel("\(name) speed in percent")
                    Text("%")
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func set(_ ease: KeyframeEase?, outgoing: Bool) {
        let key = key, time = time
        hud.onEdit { project in
            project.editComponents(of: key) { value in
                guard let frame = value.keyframe(at: time) else { return }
                value.setEase(at: time, in: outgoing ? frame.easeIn : ease, out: outgoing ? ease : frame.easeOut)
            }
        }
    }
}

/// A native, tab-reachable field with the same arithmetic and commit-on-
/// Return or focus-loss behavior as the editor's other numeric fields.
private struct EaseSpeedField: View {
    let value: Double
    let onCommit: (Double) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(value: Double, onCommit: @escaping (Double) -> Void) {
        self.value = value
        self.onCommit = onCommit
        _draft = State(initialValue: NumericExpression.format(value))
    }

    var body: some View {
        TextField("Speed in percent", text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: value) { _, value in
                if !focused { draft = NumericExpression.format(value) }
            }
            .onExitCommand {
                draft = NumericExpression.format(value)
                focused = false
            }
    }

    private func commit() {
        guard let parsed = NumericExpression.evaluate(draft), parsed.isFinite else {
            draft = NumericExpression.format(value)
            return
        }
        let speed = KeyframeEase(influence: 1, speed: parsed / 100).speed * 100
        draft = NumericExpression.format(speed)
        if speed != value { onCommit(speed) }
    }
}
