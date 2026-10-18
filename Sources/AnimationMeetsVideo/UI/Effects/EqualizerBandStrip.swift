import CoreMedia
import SwiftUI

/// An EQ's bands as fields, one row each, for the larger EQ sheet: whether
/// each is on, its frequency, gain and Q, a cut's slope, and the output.
/// The effects panel has the same in its rows, with keyframes.
struct EqualizerBandStrip: View {
    let effect: Effect
    /// The clip's source time at the playhead, where edits land.
    let time: CMTime
    let onEdit: (ControlKind, (inout EffectControl) -> Void) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Design.Space.group, verticalSpacing: 4) {
            GridRow {
                Text("Band")
                Text("Frequency")
                Text("Gain")
                Text("Q")
                Text("Slope")
            }
            .font(Design.Typeface.micro)
            .foregroundStyle(Design.textTertiary)
            ForEach(EqualizerBand.allCases) { band in
                if let control = effect.control(band.controlKind) {
                    bandRow(band, control)
                }
            }
            if let output = effect.control(.eqOutput) {
                GridRow {
                    Text(ControlKind.eqOutput.name).foregroundStyle(Design.textSecondary)
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    field(output, component: 0, name: "Output gain")
                }
            }
        }
        .font(Design.Typeface.label)
    }

    private func bandRow(_ band: EqualizerBand, _ control: EffectControl) -> some View {
        GridRow {
            Toggle(band.name, isOn: Binding(
                get: { control.enabled },
                set: { value in onEdit(band.controlKind) { $0.enabled = value } }
            ))
            .toggleStyle(.checkbox)
            .foregroundStyle(Design.textSecondary)
            .help("Switch \(band.name.lowercased()) on or off")
            field(control, component: EqualizerBand.frequencyIndex, name: "\(band.name) frequency")
            if let gain = band.gainIndex {
                field(control, component: gain, name: "\(band.name) gain")
            } else {
                Text("—").foregroundStyle(Design.textTertiary)
            }
            field(control, component: band.qIndex, name: "\(band.name) Q")
            if let slopeKind = band.slopeKind, let slope = effect.control(slopeKind) {
                Picker(slopeKind.name, selection: Binding(
                    get: { slope.choice ?? EqualizerSlope.db12.rawValue },
                    set: { value in onEdit(slopeKind) { $0.choice = value } }
                )) {
                    ForEach(EqualizerSlope.allCases) { Text($0.name).tag($0.rawValue) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("\(band.name) slope")
            }
        }
        .opacity(control.enabled ? 1 : 0.6)
    }

    private func field(_ control: EffectControl, component index: Int, name: String) -> some View {
        let kind = control.kind
        let values = control.values(at: time)
        return NumericField(
            value: values.indices.contains(index) ? values[index] : 0,
            unit: kind.unit(ofComponent: index),
            fractionDigits: kind.dragStep(ofComponent: index) < 0.1 ? 2 : 1,
            dragStep: kind.dragStep(ofComponent: index),
            dragRange: kind.range(ofComponent: index),
            accessibilityName: name
        ) { value in
            onEdit(kind) { $0.setComponent(index, to: value, at: time) }
        }
    }
}
