import SwiftUI

/// The kind of graph a Waveform draws, picked at once at the top of its
/// inspector group (docs/waveform-effect.md, "In the inspector"): a grid
/// of buttons, each a small picture of that graph (`WaveformPreview`) over
/// its name, each a setting of its Mode, Draw, Shape, Stereo and Fill to
/// Baseline (`WaveformGraph`). None is lit while the settings match none
/// of them. Tab reaches each button; VoiceOver reads its name and whether
/// it is the graph now.
struct WaveformGraphPicker: View {
    let effect: Effect
    let onEdit: ((inout Effect) -> Void) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    var body: some View {
        let current = WaveformGraph.current(of: effect)
        VStack(alignment: .leading, spacing: Design.Space.close) {
            Text("Graph")
                .foregroundStyle(Design.textSecondary)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(WaveformGraph.allCases) { graph in
                    GraphButton(graph: graph, isOn: graph == current) {
                        onEdit { graph.apply(to: &$0) }
                    }
                }
            }
            .padding(3)
            .background(Design.Surface.sunken.color, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Graph")
            .accessibilityValue(current?.name ?? "Custom")
        }
        .font(Design.Typeface.label)
    }

    /// One graph: its picture over its name, raised while it is the graph.
    private struct GraphButton: View {
        let graph: WaveformGraph
        let isOn: Bool
        let action: () -> Void

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let ink = isOn ? Design.textPrimary : Design.textSecondary
            Button(action: action) {
                VStack(spacing: 2) {
                    Canvas { context, size in WaveformGraphPicker.draw(graph, in: &context, size: size, ink: ink) }
                        .frame(height: 30)
                    Text(graph.name)
                        .font(Design.Typeface.micro)
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: Design.Radius.control - 1, style: .continuous)
                            .fill(Design.Surface.floating.color)
                            .overlay {
                                RoundedRectangle(cornerRadius: Design.Radius.control - 1, style: .continuous)
                                    .strokeBorder(Design.bevelEdgeStrong, lineWidth: 1)
                            }
                    } else if isHovered, isEnabled {
                        RoundedRectangle(cornerRadius: Design.Radius.control - 1, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("Draw a \(graph.name.lowercased()) graph; the settings below stay to change one by one")
            .accessibilityLabel(graph.name)
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }

    /// `graph`'s picture fitted to `size`, in `ink`.
    static func draw(_ graph: WaveformGraph, in context: inout GraphicsContext, size: CGSize, ink: Color) {
        let frame = WaveformPreview.frame
        let scale = min(size.width / frame.width, size.height / frame.height)
        let moved = CGAffineTransform(translationX: (size.width - frame.width * scale) / 2, y: (size.height - frame.height * scale) / 2)
            .scaledBy(x: scale, y: scale)
        for shape in WaveformPreview.shapes(of: graph) {
            context.fill(Path(shape.path).applying(moved), with: .color(ink.opacity(shape.alpha)))
        }
    }
}
