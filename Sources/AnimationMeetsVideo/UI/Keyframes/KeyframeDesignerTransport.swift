import SwiftUI

/// The same play, timecode and skimming controls as the other designers.
/// Only this row follows playback; the settings stay at the parked time.
struct KeyframeDesignerTransport: View {
    let hud: KeyframeGraphHUDs
    let frameRate: Double

    var body: some View {
        let playing = hud.playback?.isPlaying == true
        let time = playing ? hud.playback?.currentTime ?? hud.playhead : hud.playhead
        HStack(spacing: Design.Space.step) {
            ToolGlyph(tone: .keyframeDesigner)
            Button(action: hud.onTogglePlayback) {
                Image(systemName: playing ? Design.Symbol.pause : Design.Symbol.play)
                    .frame(width: 18)
            }
            .help(playing ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(playing ? "Pause" : "Play")
            Text(time.timecode(frameRate: frameRate))
                .font(Design.Typeface.timecode)
                .foregroundStyle(Design.textPrimary)
                .frame(width: 104, alignment: .leading)
                .accessibilityLabel("Playhead")
                .accessibilityValue(time.timecode(frameRate: frameRate))
            Groove(axis: .vertical).frame(height: 18)
            GraphSkimToggle(hud: hud)
            Spacer()
            Text("Changes apply immediately")
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.textSecondary)
                .help("Closing keeps your edits. Use Undo to revert a change; Bake keeps the generated keyframes and removes the method.")
        }
        .controlSize(.small)
        .frame(minHeight: 28)
        .padding(.horizontal, Design.Space.rail)
        .padding(.vertical, Design.Space.close)
        .rail(.raised)
    }
}
