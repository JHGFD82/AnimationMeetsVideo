import SwiftUI

/// The chevron that shows or hides what a row holds: an effect's settings,
/// a layer's volume, the timelines a timeline embeds. It points right
/// while closed and turns down to open, at the glyph size `Design` keeps
/// for disclosure chevrons, in a 12-point square that all takes the click.
///
/// VoiceOver reads `label` as a button whose value is shown or hidden.
struct DisclosureChevron: View {
    let isExpanded: Bool
    /// What it shows or hides: "Blur's settings".
    let label: String
    /// Help, when it should say more than "Show" or "Hide" and the label.
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(Design.Typeface.glyphSmall)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .editorAnimation(Design.Motion.select, value: isExpanded)
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Design.textSecondary)
        .help(help ?? (isExpanded ? "Hide \(label)" : "Show \(label)"))
        .accessibilityLabel(label)
        .accessibilityValue(isExpanded ? "Shown" : "Hidden")
    }
}
