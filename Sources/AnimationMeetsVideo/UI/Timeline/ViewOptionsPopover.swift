import SwiftUI

struct ViewOptionsPopover: View {
    /// 0 fits the whole timeline; 1 is the closest zoom.
    @Binding var zoomFraction: Double
    let onFit: () -> Void
    @Binding var layerHeight: CGFloat
    /// Layers with beats, as (layer ID, name), in timeline order.
    let beatLayers: [(id: UUID, name: String)]
    @Binding var beatLayerID: UUID?

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
                }
            }
        }
        .padding()
        .frame(width: 260)
    }
}
