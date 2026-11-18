import SwiftUI

/// The chain between a width and a height that keeps them changing
/// together: in the effects panel's rows and in the inspector's fields.
/// Primary ink while linked, tertiary while not, and read by VoiceOver as
/// a toggle that is on or off.
struct LinkToggle: View {
    let isLinked: Bool
    /// The row's height, so the target fills it.
    var height: CGFloat = 18
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "link")
                .font(Design.Typeface.micro)
                .foregroundStyle(isLinked ? Design.textPrimary : Design.textTertiary)
                .frame(width: 14, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isLinked ? "Width and height change together" : "Width and height change separately")
        .accessibilityLabel("Link width and height")
        .accessibilityValue(isLinked ? "on" : "off")
    }
}
