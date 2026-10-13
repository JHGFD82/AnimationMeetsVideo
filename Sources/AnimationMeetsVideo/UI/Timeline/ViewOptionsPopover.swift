import SwiftUI

struct ViewOptionsPopover: View {
    @Binding var zoomScale: CGFloat
    @Binding var layerHeight: CGFloat
    /// Layers with beats, as (layer ID, name), in timeline order.
    let beatLayers: [(id: UUID, name: String)]
    @Binding var beatLayerID: UUID?

    var body: some View {
        Form {
            Section("Horizontal Zoom") {
                Slider(value: $zoomScale, in: 1...30)
                Button("Fit to Window") { zoomScale = 1 }
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
