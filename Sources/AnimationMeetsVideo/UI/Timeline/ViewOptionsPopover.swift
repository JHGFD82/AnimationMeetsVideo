import SwiftUI

struct ViewOptionsPopover: View {
    /// 0 fits the whole timeline; 1 is the closest zoom.
    @Binding var zoomFraction: Double
    let onFit: () -> Void
    /// Which areas show, and each one's layer height.
    @Binding var areaLayout: TimelineAreaLayout
    /// Layers with beats, as (layer ID, name), in timeline order.
    let beatLayers: [(id: UUID, name: String)]
    @Binding var beatLayerID: UUID?
    @Binding var clickOnBeats: Bool
    /// The click's pitch, in hertz.
    @Binding var clickFrequency: Double
    let onPreviewClick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.group + 2) {
            SheetSection("Zoom") {
                Slider(value: $zoomFraction, in: 0...1)
                Button("Fit to window", action: onFit)
                    .help("Also on the \\ key")
            }

            Groove()

            SheetSection("Areas") {
                ForEach(TimelineAreaLayout.order) { kind in
                    HStack(spacing: Design.Space.step) {
                        Toggle(kind.name, isOn: Binding(
                            get: { areaLayout.isShown(kind) },
                            set: { areaLayout.setShown(kind, $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .frame(width: 72, alignment: .leading)
                        // Layer height: the same as pinching vertically
                        // over the area.
                        Slider(
                            value: Binding(
                                get: { areaLayout.layerHeight(kind) },
                                set: { areaLayout.setLayerHeight(kind, $0) }
                            ),
                            in: TimelineAreaLayout.layerHeightRange
                        )
                        .disabled(!areaLayout.isShown(kind))
                        .help("Layer height in the \(kind.name.lowercased()) area; pinch up and down over it to change it too")
                    }
                }
            }

            Groove()

            SheetSection("Beat markers") {
                if beatLayers.isEmpty {
                    Text("No audio on this timeline has detected beats yet.")
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
                        HStack(spacing: Design.Space.close) {
                            Text("Pitch")
                                .font(Design.Typeface.label)
                                .foregroundStyle(Design.textSecondary)
                            Slider(value: $clickFrequency, in: BeatClickPlayer.frequencyRange, step: 10) { editing in
                                if !editing { onPreviewClick() }
                            }
                            Text("\(Int(clickFrequency)) Hz")
                                .font(Design.Typeface.numericSmall)
                                .foregroundStyle(Design.textPrimary)
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
        .padding(Design.Space.rail)
        .frame(width: 300)
        .background(Design.Surface.overlay.color)
    }
}
