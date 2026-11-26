import SwiftUI

/// The kind of graph a Waveform draws, picked at once at the top of its
/// inspector group (docs/waveform-effect.md, "In the inspector"): Wave,
/// Filled, Dots, Bars, Ring or Scope, each a setting of its Mode, Draw,
/// Shape, Stereo and Fill to Baseline (`WaveformGraph`). None is lit
/// while the settings match none of them.
struct WaveformGraphPicker: View {
    let effect: Effect
    let onEdit: ((inout Effect) -> Void) -> Void

    var body: some View {
        InspectorLabelledRow("Graph") {
            PanelSegmentedPicker(
                name: "Graph",
                segments: WaveformGraph.allCases.map { PanelSegment(value: Optional($0), glyph: .symbol($0.systemImage), name: $0.name) },
                selection: WaveformGraph.current(of: effect),
                fills: true
            ) { picked in
                guard let picked else { return }
                onEdit { picked.apply(to: &$0) }
            }
        }
        .help("The kind of graph: a wave, a filled wave, dots, spectrum bars, a ring or a stereo scope")
    }
}
