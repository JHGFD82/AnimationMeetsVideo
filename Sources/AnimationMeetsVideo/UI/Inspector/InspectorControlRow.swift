import CoreGraphics
import CoreMedia
import SwiftUI

/// The controls of `kinds` an effect has, in that order, as inspector rows.
/// One deleted in the effects panel isn't shown.
struct InspectorControls: View {
    let effect: Effect
    let kinds: [ControlKind]
    let playhead: PlayheadTime
    let onEdit: ((inout Effect) -> Void) -> Void
    let onSeek: (CMTime) -> Void

    var body: some View {
        ForEach(kinds.compactMap { effect.control($0) }) { control in
            InspectorControlRow(
                control: control, playhead: playhead,
                onEdit: { change in onEdit { $0.changeControl(control.kind, change) } },
                onSeek: onSeek
            )
        }
    }
}

/// One control of an effect in the inspector, laid out like the sound rows:
///
/// - numbers: a stopwatch that animates them, the name, each component's
///   value at the playhead (click to type, drag to change), a link for a
///   size's axes, and once animated the keyframe buttons;
/// - a color: the same, with a checkbox that turns it on or off (a shape's
///   Fill or Stroke left out) and a color well;
/// - a choice: a menu, the alignment's icons, or for an on-or-off setting
///   a checkbox.
///
/// Edits land at the playhead, so an animated control gets a keyframe there.
struct InspectorControlRow: View {
    let control: EffectControl
    /// The playhead in the clip's source time, snapped to a frame.
    let playhead: PlayheadTime
    let onEdit: ((inout EffectControl) -> Void) -> Void
    /// Moves the playhead to a time in the clip's source time.
    let onSeek: (CMTime) -> Void

    /// The width of a row's name, after the stopwatch.
    static let nameWidth: CGFloat = 112

    private var kind: ControlKind { control.kind }
    private var lowercaseName: String { kind.name.lowercased() }

    var body: some View {
        Group {
            if kind.isChoice {
                choiceRow
            } else {
                numberRow
            }
        }
        .font(Design.Typeface.label)
    }

    // MARK: Choices

    @ViewBuilder
    private var choiceRow: some View {
        let picked = control.choice ?? kind.defaultChoice ?? ""
        if Set(kind.choiceOptions.map(\.id)) == Set(OnOff.allCases.map(\.rawValue)) {
            Toggle(kind.name, isOn: Binding(
                get: { picked == OnOff.on.rawValue },
                set: { isOn in onEdit { $0.choice = (isOn ? OnOff.on : .off).rawValue } }
            ))
            .toggleStyle(.checkbox)
            .foregroundStyle(Design.textSecondary)
            .padding(.leading, 22)
            .disabled(!control.enabled)
        } else {
            HStack(spacing: 4) {
                Color.clear.frame(width: 18, height: 1)
                name
                if kind == .textAlign {
                    alignmentPicker(picked)
                } else {
                    Picker(kind.name, selection: Binding(get: { picked }, set: { choice in onEdit { $0.choice = choice } })) {
                        ForEach(kind.choiceOptions, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 150, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .disabled(!control.enabled)
        }
    }

    /// The seven alignments as icons, as in Illustrator's Paragraph panel.
    private func alignmentPicker(_ picked: String) -> some View {
        Picker(kind.name, selection: Binding(get: { picked }, set: { choice in onEdit { $0.choice = choice } })) {
            ForEach(TextAlign.allCases) { align in
                Image(systemName: align.systemImage)
                    .accessibilityLabel(align.name)
                    .help(align.name)
                    .tag(align.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    // MARK: Numbers

    private var numberRow: some View {
        let time = playhead.shown(animated: control.isAnimated)
        let values = control.values(at: time)
        return HStack(spacing: 4) {
            AnimateToggle(name: lowercaseName, isAnimated: control.isAnimated) {
                let at = playhead.current
                onEdit { $0.number.setAnimated(!$0.number.isAnimated, at: at) }
            }
            name
            if kind.isColor {
                colorFields(values)
            } else {
                if kind.isLinkable {
                    Button {
                        onEdit { $0.linked.toggle() }
                    } label: {
                        Image(systemName: "link")
                            .foregroundStyle(control.linked ? Design.textPrimary : Design.textTertiary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(control.linked ? "Width and height change together" : "Width and height change separately")
                    .accessibilityLabel("Link width and height")
                    .accessibilityValue(control.linked ? "on" : "off")
                }
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    NumericField(
                        value: value, unit: kind.unit(ofComponent: index), fractionDigits: kind.dragStep(ofComponent: index) < 1 ? 2 : 1,
                        label: kind == .leading ? { $0 == 0 ? "Auto" : kind.label($0) } : nil,
                        dragStep: kind.dragStep(ofComponent: index), dragRange: kind.range(ofComponent: index),
                        accessibilityName: values.count > 1 ? "\(kind.name) \(componentName(index))" : kind.name
                    ) { newValue in
                        let at = playhead.current
                        onEdit { $0.setComponent(index, to: newValue, at: at) }
                    }
                    .help(values.count > 1 ? componentName(index) : kind.name)
                }
                .disabled(!control.enabled)
            }
            Spacer(minLength: 4)
            if control.isAnimated {
                KeyframeNavigator(
                    name: lowercaseName, keyframeTimes: control.number.keyframes.map(\.time), time: time, onSeek: onSeek,
                    onToggle: {
                        let at = playhead.current
                        onEdit { $0.number.toggleKeyframe(at: at) }
                    }
                )
            }
        }
    }

    /// A color's checkbox, which leaves it out when off, and its well.
    @ViewBuilder
    private func colorFields(_ values: [Double]) -> some View {
        Toggle("Use \(lowercaseName)", isOn: Binding(get: { control.enabled }, set: { on in onEdit { $0.enabled = on } }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(control.enabled ? "Turn off to leave the \(lowercaseName) out" : "Turn on to draw the \(lowercaseName)")
        HeldColorWell(name: kind.name, selection: Binding(
            get: {
                let rgba = values.map { CGFloat($0) }
                guard rgba.count == 4 else { return CGColor(gray: 1, alpha: 1) }
                return CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
            },
            set: { picked in
                // Read as sRGB, which is how the components are drawn.
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let srgb = picked.converted(to: space, intent: .defaultIntent, options: nil),
                      let parts = srgb.components, parts.count >= 4
                else { return }
                let values = parts.prefix(4).map { kind.clamped(Double($0)) }
                let at = playhead.current
                onEdit { $0.number.set(ComponentValue(values: values), at: at) }
            }
        ))
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel(kind.name)
        .disabled(!control.enabled)
        if values.count == 4 {
            Text("\(Int((values[3] * 100).rounded()))%")
                .font(Design.Typeface.numericSmall)
                .foregroundStyle(Design.textTertiary)
                .help("Opacity, set in the color well")
                .accessibilityLabel("\(kind.name) opacity")
        }
    }

    /// What one component is called ("Width", "Gap").
    private func componentName(_ index: Int) -> String {
        kind.componentNames.indices.contains(index) ? kind.componentNames[index] : kind.name
    }

    private var name: some View {
        Text(kind.name)
            .foregroundStyle(Design.textSecondary)
            .lineLimit(1)
            .frame(width: Self.nameWidth, alignment: .leading)
    }
}
