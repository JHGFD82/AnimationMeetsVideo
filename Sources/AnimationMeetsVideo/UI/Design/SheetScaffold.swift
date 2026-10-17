import AppKit
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
/// can change, what happens next. The frame puts the actions in the footer,
/// trailing; it doesn't order them or give them keys. Each dialog lists the
/// confirming action last, as macOS dialogs do, and marks it
/// `.keyboardShortcut(.defaultAction)`, and its cancelling one
/// `.cancelAction`. A dialog with one action that closes it handles Escape
/// itself (`onExitCommand`).
///
/// Text: titles, subtitles, labels and notes are display text, shown as
/// given (`Text(verbatim:)`), never looked up as localization keys. The app
/// isn't localized; when it is, callers pass localized strings, which keeps
/// names that come from the project, such as a file's, out of any lookup.
struct SheetFrame<Content: View, Actions: View>: View {
    let title: String
    /// One line on what the dialog is for, or why it appeared. Worth
    /// writing: it is the only place a dialog can explain itself.
    var subtitle: String?
    var width: CGFloat = Design.SheetWidth.standard
    /// Scrolls the content between the title and the footer when it would
    /// be taller than the screen leaves room for, so the actions stay in
    /// reach. For long forms; content that already scrolls (a `List`, a
    /// `ScrollView`) bounds itself and leaves this off.
    var scrollsContent = false
    /// False for a dialog with no actions, which then ends at its content.
    private let showsFooter: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    /// The title block's and footer's heights, measured, which scrolling
    /// content leaves room for.
    @State private var titleHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    init(
        title: String,
        subtitle: String? = nil,
        width: CGFloat = Design.SheetWidth.standard,
        scrollsContent: Bool = false,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.scrollsContent = scrollsContent
        self.showsFooter = true
        self.content = content
        self.actions = actions
    }

    fileprivate init(
        title: String,
        subtitle: String?,
        width: CGFloat,
        scrollsContent: Bool,
        showsFooter: Bool,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.scrollsContent = scrollsContent
        self.showsFooter = showsFooter
        self.content = content
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(Design.Typeface.title)
                    .foregroundStyle(Design.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(Design.Typeface.body)
                        .foregroundStyle(Design.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.Space.sheet)
            .padding(.vertical, Design.Space.group + 2)
            .rail(.raised)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { titleHeight = $0 }

            if scrollsContent {
                ScrollView {
                    contentStack
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: maxContentHeight)
                .panelSurface(.floating)
            } else {
                contentStack
                    .panelSurface(.floating)
            }

            if showsFooter {
                // Side by side, or stacked when long titles wouldn't fit.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Design.Space.step) { actions() }
                    VStack(alignment: .trailing, spacing: Design.Space.step) { actions() }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, Design.Space.sheet)
                .padding(.vertical, Design.Space.group)
                .background(Design.Surface.raised.color)
                .overlay(alignment: .top) { Groove() }
                // A filled action reads its white title at 4.5:1 or better.
                .tint(Design.accentFill)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { footerHeight = $0 }
            }
        }
        .frame(width: width)
        .background(Design.Surface.floating.color)
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: Design.Space.group + 2) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Design.Space.sheet)
    }

    /// How tall scrolling content may grow: what the screen the dialog is
    /// on leaves once the title and footer are placed, less room for the
    /// title bar the sheet hangs from and a margin above the Dock.
    private var maxContentHeight: CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let available = screen?.visibleFrame.height ?? 800
        return max(160, available - titleHeight - footerHeight - 120)
    }
}

extension SheetFrame where Actions == EmptyView {
    /// A dialog with no actions: it has no footer and ends at its content.
    init(
        title: String,
        subtitle: String? = nil,
        width: CGFloat = Design.SheetWidth.standard,
        scrollsContent: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title, subtitle: subtitle, width: width, scrollsContent: scrollsContent,
            showsFooter: false, content: content
        ) { EmptyView() }
    }
}

/// A labelled group of options inside a sheet. The heading is a plain
/// sentence-case word, not a tracked-out all-caps label. Groups are set
/// apart by the sheet's spacing; a dialog that wants a rule between two
/// places a `Groove()` there itself.
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
                Text(verbatim: title)
                    .font(Design.Typeface.groupTitle)
                    .foregroundStyle(Design.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One option: its name in the label column, its control in the rest.
/// Every sheet uses the same column width, so controls line up down a
/// dialog and across the app. A long name wraps in its column.
///
/// The label is only seen, not tied to the controls for VoiceOver, since a
/// row may hold several. Each control names itself: give it its own label
/// (a text field's or picker's, hidden with `.labelsHidden()` where the
/// row's label shows instead, or `.accessibilityLabel`), and put a note's
/// instruction on the controls it is about with `.accessibilityHint`.
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
            Text(verbatim: label)
                .font(Design.Typeface.body)
                .foregroundStyle(Design.textSecondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Design.Space.sheetLabelColumn, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Explanatory text under a control, in the control's column so it reads as
/// belonging to it rather than to the group. VoiceOver reads it where it is;
/// an instruction the control needs goes on the control too, as its hint.
struct SheetNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: Design.Space.group) {
            Color.clear.frame(width: Design.Space.sheetLabelColumn, height: 1)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A line that needs attention inside a sheet: a mismatch found, a check
/// that failed, a warning about what a replacement will lose. VoiceOver
/// reads it as one line, its severity first ("Warning: …").
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

        /// What the color and symbol say, in words.
        var severity: String {
            switch self {
            case .info: String(localized: "Note", comment: "Severity of an information callout, read before its message")
            case .warning: String(localized: "Warning", comment: "Severity of a warning callout, read before its message")
            case .danger: String(localized: "Error", comment: "Severity of an error callout, read before its message")
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
            Text(verbatim: text)
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
                .decorative()
        }
        // One announcement, severity then message, and not the symbol's name.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(tone.severity): \(text)"))
    }
}
