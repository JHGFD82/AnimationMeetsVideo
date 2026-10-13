import SwiftUI

struct ViewOptionsPopover: View {
    /// 0 fits the whole timeline; 1 is the closest zoom.
    @Binding var zoomFraction: Double
    let onFit: () -> Void
    @Binding var layerHeight: CGFloat
    /// Layers with beats, as (layer ID, name), in timeline order.
    let beatLayers: [(id: UUID, name: String)]
    @Binding var beatLayerID: UUID?
    @Binding var clickOnBeats: Bool
    /// The click's pitch, in hertz.
    @Binding var clickFrequency: Double
    let onPreviewClick: () -> Void

    var body: some View {
        Form {
            Section("Horizontal Zoom") {
                Slider(value: $zoomFraction, in: 0...1)
                Button("Fit to Window (\\)", action: onFit)
            }
            Section("Layer Height") {
                Slider(value: $layerHeight, in: 32...120)
            }
            Section("Beat Markers") {
                if beatLayers.isEmpty {
                    Text("No audio on this timeline has detected beats.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Show beats of", selection: $beatLayerID) {
                        Text("None").tag(UUID?.none)
                        ForEach(beatLayers, id: \.id) { layer in
                            Text(layer.name).tag(UUID?.some(layer.id))
                        }
                    }
                    Toggle("Click on beats", isOn: $clickOnBeats)
                        .disabled(beatLayerID == nil)
                    if clickOnBeats {
                        LabeledContent("Pitch") {
                            HStack(spacing: 6) {
                                Slider(value: $clickFrequency, in: BeatClickPlayer.frequencyRange, step: 10) { editing in
                                    if !editing { onPreviewClick() }
                                }
                                Text("\(Int(clickFrequency)) Hz")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 52, alignment: .trailing)
                                Button(action: onPreviewClick) {
                                    Image(systemName: "speaker.wave.2")
                                }
                                .buttonStyle(.borderless)
                                .help("Preview the click")
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 300)
    }
}
