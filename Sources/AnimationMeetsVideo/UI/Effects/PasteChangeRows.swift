import SwiftUI

extension Notification.Name {
    /// Posted when a preset is saved, so the browser lists it.
    static let presetsChanged = Notification.Name("AnimationMeetsVideo.presetsChanged")
}

/// What pasting couldn't bring over, listed under the effect it is about
/// with a button to mark each change resolved (see docs/effects.md, "Paste
/// changes").
extension EffectsPanel {
    func pasteChangeRow(_ change: PasteChange, of effect: Effect, in clip: TimelineClip) -> some View {
        besideLane(
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Design.Typeface.glyphSmall)
                    .padding(.top, 1)
                Text(change.message)
                    .font(Design.Typeface.micro)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                Button("Mark Resolved") {
                    project.resolvePasteChange(change, ofEffect: effect.id, onClip: clip.id, in: timelineID)
                }
                .controlSize(.mini)
                .help("You have dealt with this; the effect stays as it is, and the clip can be exported")
            }
            .foregroundStyle(Design.statusWarning)
            .padding(.leading, EffectsPanelMetrics.controlIndent)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
        )
        .overlay(alignment: .bottom) { Rectangle().fill(Design.hairline).frame(height: 0.5) }
    }
}
