import SwiftUI

/// Where the beat tick's settings are remembered. The timeline's view
/// options and the beat match panel share them, so there is one tick.
enum ClickToneSettings {
    static let frequencyKey = "beatClickFrequency"
    static let volumeKey = "beatClickVolume"
    static let defaultFrequency = 1000.0
    static let defaultVolume = 0.8
}

/// The beat tick's pitch and volume, with a button to hear it. Letting go
/// of either slider plays one tick too.
struct ClickToneControls: View {
    @Binding var frequency: Double
    /// 0 (silent) to 1 (full).
    @Binding var volume: Double
    let onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.close) {
            HStack(spacing: Design.Space.close) {
                label("Pitch")
                Slider(value: $frequency, in: BeatClickPlayer.frequencyRange, step: 10) { editing in
                    if !editing { onPreview() }
                }
                .accessibilityLabel("Tick pitch")
                .accessibilityValue("\(Int(frequency)) hertz")
                reading("\(Int(frequency)) Hz")
                Button(action: onPreview) {
                    Image(systemName: "speaker.wave.2")
                }
                .buttonStyle(.borderless)
                .help("Preview the tick")
                .accessibilityLabel("Preview the tick")
            }
            HStack(spacing: Design.Space.close) {
                label("Volume")
                Slider(value: $volume, in: 0...1) { editing in
                    if !editing { onPreview() }
                }
                .accessibilityLabel("Tick volume")
                .accessibilityValue("\(Int((volume * 100).rounded())) percent")
                reading("\(Int((volume * 100).rounded()))%")
                // Keeps the sliders the same length.
                Image(systemName: "speaker.wave.2").hidden().accessibilityHidden(true)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Design.Typeface.label)
            .foregroundStyle(Design.textSecondary)
            .frame(width: 48, alignment: .leading)
            .accessibilityHidden(true)
    }

    private func reading(_ text: String) -> some View {
        Text(text)
            .font(Design.Typeface.numericSmall)
            .foregroundStyle(Design.textPrimary)
            .frame(width: 52, alignment: .trailing)
            .accessibilityHidden(true)
    }
}
