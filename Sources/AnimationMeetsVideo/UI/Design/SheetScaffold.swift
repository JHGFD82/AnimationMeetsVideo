import SwiftUI

/// One shape for every dialog in the editor.
///
/// The sheets grew up separately and showed it: three different widths,
/// three different paddings, titles that were sometimes `.headline` and
/// sometimes `.title3`, and options laid out as whatever control came to
/// hand. `SheetFrame` fixes the parts that should never vary — a title
/// block that says what the dialog is for, options in labelled groups with
/// one label column, and actions in a footer rail — so the only thing a
/// dialog has to decide is its content.
///
/// Reading order is top to bottom, left to right: what this is, what you
/// can change, what happens next. Actions sit at the bottom right with the
/// confirming one last, the way every other macOS dialog puts them.
struct SheetFrame<Content: View, Actions: View>: View {
    let title: String
    /// One line on what the dialog is for, or why it appeared. Worth
    /// writing: it is the only place a dialog can explain itself.
    var subtitle: String?
    var width: CGFloat = Design.SheetWidth.standard
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Design.Typeface.title)
                    .foregroundStyle(Design.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Design.Typeface.body)
                        .foregroundStyle(Design.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.Space.sheet)
            .padding(.vertical, Design.Space.group + 2)
            .rail(.raised)

            VStack(alignment: .leading, spacing: Design.Space.group + 2) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Design.Space.sheet)
            .panelSurface(.floating)

            HStack(spacing: Design.Space.step) {
                actions()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, Design.Space.sheet)
            .padding(.vertical, Design.Space.group)
            .background(Design.Surface.raised.color)
            .overlay(alignment: .top) { Groove() }
        }
        .frame(width: width)
        .background(Design.Surface.floating.color)
    }
}

extension SheetFrame where Actions == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        width: CGFloat = Design.SheetWidth.standard,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, width: width, content: content) { EmptyView() }
    }
}

/// A labelled group of options inside a sheet. The heading is a plain
/// sentence-case word, not a tracked-out all-caps label — the rule above it
/// is what separates the group.
struct SheetSection<Content: View>: View {
    let title: String?
    var spacing: CGFloat = Design.Space.step
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, spacing: CGFloat = Design.Space.step, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title {
                Text(title)
                    .font(Design.Typeface.groupTitle)
                    .foregroundStyle(Design.textSecondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One option: its name in the label column, its control in the rest.
/// Every sheet uses the same column width, so controls line up down a
/// dialog and across the app.
struct SheetRow<Content: View>: View {
    /// The one label column every sheet shares. Lives on `Design` rather
    /// than here so `SheetNote` can line up with it without naming
    /// `SheetRow`'s generic parameter.
    static var labelWidth: CGFloat { Design.Space.sheetLabelColumn }

    let label: String
    var alignment: VerticalAlignment = .firstTextBaseline
    @ViewBuilder let content: () -> Content

    init(_ label: String, alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.alignment = alignment
        self.content = content
    }

    var body: some View {
        HStack(alignment: alignment, spacing: Design.Space.group) {
            Text(label)
                .font(Design.Typeface.body)
                .foregroundStyle(Design.textSecondary)
                .frame(width: Design.Space.sheetLabelColumn, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Explanatory text under a control, in the control's column so it reads as
/// belonging to it rather than to the group.
struct SheetNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: Design.Space.group) {
            Color.clear.frame(width: Design.Space.sheetLabelColumn, height: 1)
            Text(text)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A line that needs attention inside a sheet: a mismatch found, a check
/// that failed, a warning about what a replacement will lose.
struct SheetCallout: View {
    enum Tone {
        case info, warning, danger

        var color: Color {
            switch self {
            case .info: Design.accent
            case .warning: Design.statusWarning
            case .danger: Design.statusDanger
            }
        }

        var symbol: String {
            switch self {
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .danger: "xmark.octagon"
            }
        }
    }

    let tone: Tone
    let text: String

    init(_ tone: Tone, _ text: String) {
        self.tone = tone
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: Design.Space.step) {
            Image(systemName: tone.symbol)
                .foregroundStyle(tone.color)
            Text(text)
                .font(Design.Typeface.body)
                .foregroundStyle(Design.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Design.Space.step + 2)
        .background(tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                .strokeBorder(tone.color.opacity(0.35), lineWidth: 1)
        }
    }
}
