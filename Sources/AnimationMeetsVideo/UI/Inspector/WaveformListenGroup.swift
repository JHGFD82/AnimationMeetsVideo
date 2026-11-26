import SwiftUI

/// What a Waveform listens to, in the inspector (see
/// docs/waveform-effect.md, "What it listens to"): the whole mix, a Sound
/// or Music layer, or one clip with sound, of the timeline its clip is in,
/// as Audio Keys' Listen To offers them.
struct WaveformListenGroup: View {
    let effect: Effect
    /// From `EditingProject.audioSourceOptions`.
    let options: [(id: String, name: String)]
    let onEdit: ((inout Effect) -> Void) -> Void

    var body: some View {
        InspectorGroup("\(effect.displayName) · Sound") {
            HStack(spacing: 4) {
                Text("Listen To")
                    .foregroundStyle(Design.textSecondary)
                    .frame(width: InspectorControlRow.nameWidth, alignment: .leading)
                    .accessibilityHidden(true)
                PanelMenuField(
                    glyph: nil, name: "Listen To", options: options.map { ($0.id, $0.name) },
                    selection: effect.listensTo.optionID
                ) { picked in
                    onEdit { $0.listensTo = AudioKeysSource(optionID: picked) }
                }
                .help("The sound it draws: the whole mix, one Sound or Music layer, or one clip, as heard")
            }
            .font(Design.Typeface.label)
        }
    }
}
