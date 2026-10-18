import SwiftUI

/// The editor's small controls: icon buttons on rails, and the key a
/// command answers to.
///
/// Icon buttons had grown three looks — bordered capsules, borderless
/// glyphs in the accent, plain glyphs — so the same zoom button was grey in
/// one panel and blue in the next. One style now: a quiet glyph that lifts
/// on hover, sinks when pressed, and takes the accent only when it is a
/// toggle that is on. The accent keeps its one meaning, selection and
/// state, rather than "this is clickable".

// MARK: - Icon buttons

/// A glyph on a rail: secondary ink at rest, a raised fill under the
/// pointer, sunk while pressed, and the accent while `isOn`.
struct IconButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, isOn: isOn)
    }

    private struct IconButtonBody: View {
        let configuration: Configuration
        let isOn: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(Design.Typeface.icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ink)
                .frame(minWidth: Design.IconButton.size, minHeight: Design.IconButton.size)
                .padding(.horizontal, 2)
                .background(fill, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                .onHover { isHovered = $0 }
                .editorAnimation(Design.Motion.select, value: isHovered)
        }

        private var ink: Color {
            guard isEnabled else { return Design.textTertiary.opacity(0.5) }
            if isOn { return Design.accent }
            return isHovered || configuration.isPressed ? Design.textPrimary : Design.textSecondary
        }

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Color.black.opacity(0.25) }
            if isOn { return Design.accent.opacity(0.16) }
            return isHovered ? Color.white.opacity(0.07) : .clear
        }
    }
}

/// A toggle drawn as an icon button that holds the accent while on.
struct IconToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(IconButtonStyle(isOn: configuration.isOn))
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    /// A glyph on a rail. See `IconButtonStyle`.
    static var icon: IconButtonStyle { IconButtonStyle() }
}

extension ToggleStyle where Self == IconToggleStyle {
    /// An icon button that stays lit while on. See `IconButtonStyle`.
    static var icon: IconToggleStyle { IconToggleStyle() }
}

extension Design {
    enum IconButton {
        /// The square every icon button fills, so a row of them lines up
        /// and each is a comfortable target.
        static let size: CGFloat = 24
    }
}

// MARK: - Keys

/// The key a command answers to, set as a small keycap beside it, so the
/// shortcut is learned without being part of the command's name. Hidden
/// from VoiceOver: the control's help says the key in words.
struct KeyCap: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(verbatim: key)
            .font(Design.Typeface.numericMicro)
            .foregroundStyle(Design.textSecondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 15)
            .beveledChip(fill: Design.Surface.overlay.color, radius: Design.Radius.chip)
            .accessibilityHidden(true)
    }
}
