import SwiftUI

/// What a control's badge says about the method making its keyframes (a
/// Keyframing effect, which the stack doesn't list), so a row is redrawn
/// when it changes.
struct KeyframeMethodBadgeInfo: Equatable {
    var name: String
    var systemImage: String
    /// Why it can't write, or that it waits on the person: drawn in the
    /// warning tone, and said in the help and to VoiceOver.
    var attention: String?

    /// The badge for the method driving `target` on `clip`, if one does.
    init?(driving target: KeyframingTarget, in clip: TimelineClip, of timeline: Timeline, project: EditingProject) {
        guard let effect = project.keyframingEffect(driving: target, in: clip) else { return nil }
        name = effect.displayName
        systemImage = effect.kind.systemImage
        if project.keyframingFreshness(of: effect, in: clip, of: timeline) == .outOfDateWithEdits {
            attention = "What it reads has changed since its keyframes were edited by hand: open the Keyframe Designer to Regenerate or Keep Edits."
        } else if let note = project.keyframingNote(for: effect, in: clip, of: timeline), note.dims {
            attention = note.text
        }
    }
}

/// A small badge on a control's row naming the method that makes its
/// keyframes (Wiggler, Audio Keys, …): its glyph in the generated
/// keyframes' tone, or the warning tone when it needs attention. A click
/// opens the Keyframe Designer on the control.
struct KeyframeMethodBadge: View {
    let info: KeyframeMethodBadgeInfo
    let onOpen: () -> Void

    var body: some View {
        let tone = info.attention == nil ? Design.generatedKeyframe : Design.statusWarning
        Button(action: onOpen) {
            Image(systemName: info.attention == nil ? info.systemImage : "exclamationmark.triangle.fill")
                .font(Design.Typeface.glyphTiny)
                .foregroundStyle(tone)
                .frame(width: 22, height: 14)
                .background(Capsule().fill(tone.opacity(0.18)))
                .overlay(Capsule().strokeBorder(tone.opacity(0.6), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Keyframes made by \(info.name)\(info.attention.map { ". \($0)" } ?? ""). Click to open the Keyframe Designer.")
        .accessibilityLabel("Keyframes made by \(info.name)")
        .accessibilityValue(info.attention.map { "Warning: \($0)" } ?? "")
        .accessibilityHint("Opens the Keyframe Designer")
    }
}
