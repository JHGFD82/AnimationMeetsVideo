import CoreGraphics
import CoreMedia
import Foundation

/// What a Text effect writes, which isn't a control: the words, the font
/// they are set in, and what some letters set differently (see
/// docs/graphic-layers.md, "Text"). Its size, alignment, tracking and the
/// rest are controls, so they can be keyframed like any other.
struct TextContent: Equatable, Sendable {
    /// The words, with a line break for each new line.
    var string = "Text"
    /// The font's PostScript name, which names one style of one family
    /// ("HelveticaNeue-Bold"). Kept even when the font isn't installed,
    /// which then draws with a substitute (see `FontCatalog.isInstalled`).
    var fontName = TextContent.defaultFontName
    /// Letters styled apart from the block, in order, none overlapping.
    var runs: [TextRun] = []

    init(string: String = "Text", fontName: String = TextContent.defaultFontName, runs: [TextRun] = []) {
        self.string = string
        self.fontName = fontName
        self.runs = runs
    }

    /// A heavy sans serif every Mac has.
    static let defaultFontName = "HelveticaNeue-Bold"
}

/// How the lines of a text block line up with each other, as Illustrator's
/// Paragraph panel offers. The justified ones stretch every wrapped line of
/// a paragraph but its last to the wrap width, and line the last up as
/// they say (or stretch it too, for Justify All). Unwrapped, every line is
/// a paragraph's last.
enum TextAlign: String, CaseIterable, Identifiable, Sendable {
    case left, center, right
    /// Justified, its last line on the left.
    case justified
    case justifyCenter, justifyRight, justifyAll

    var id: Self { self }

    var name: String {
        switch self {
        case .left: "Align Left"
        case .center: "Align Center"
        case .right: "Align Right"
        case .justified: "Justify, Last Line Left"
        case .justifyCenter: "Justify, Last Line Centered"
        case .justifyRight: "Justify, Last Line Right"
        case .justifyAll: "Justify All Lines"
        }
    }

    var systemImage: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify.left"
        case .justifyCenter: "text.justify"
        case .justifyRight: "text.justify.right"
        case .justifyAll: "line.3.horizontal"
        }
    }

    var isJustified: Bool { self != .left && self != .center && self != .right }

    /// How a paragraph's last line lines up, and every unwrapped line.
    var lastLine: TextAlign {
        switch self {
        case .justified: .left
        case .justifyCenter: .center
        case .justifyRight: .right
        default: self
        }
    }
}

/// Whether letters are spaced by the font's kerning pairs.
enum TextKerning: String, CaseIterable, Identifiable, Sendable {
    /// The pairs the font's designer set ("AV" closer than "HH").
    case metrics
    case none

    var id: Self { self }

    var name: String {
        switch self {
        case .metrics: "Metrics"
        case .none: "None"
        }
    }
}

/// The letters' case, drawn without changing the words typed.
enum TextCase: String, CaseIterable, Identifiable, Sendable {
    case normal, allCaps
    /// Lowercase letters as the font's small capitals ('smcp').
    case smallCaps
    /// Capitals too ('c2sc').
    case allSmallCaps

    var id: Self { self }

    var name: String {
        switch self {
        case .normal: "Normal"
        case .allCaps: "All Caps"
        case .smallCaps: "Small Caps"
        case .allSmallCaps: "All Small Caps"
        }
    }
}

/// Where letters sit: on the baseline, or small and raised or lowered.
enum TextPosition: String, CaseIterable, Identifiable, Sendable {
    case normal, superscript, `subscript`

    var id: Self { self }

    var name: String {
        switch self {
        case .normal: "Normal"
        case .superscript: "Superscript"
        case .subscript: "Subscript"
        }
    }

    /// The font's OpenType feature for it, which draws its own designed
    /// letters where the font has them.
    var feature: String? {
        switch self {
        case .normal: nil
        case .superscript: "sups"
        case .subscript: "subs"
        }
    }

    /// Without the feature, as Illustrator makes them: this much of the size.
    static let syntheticSize = 0.583
    /// Raised (or lowered) by this much of the size.
    static let syntheticShift = 0.333
}

/// Which of the font's ligatures join letters.
enum TextLigatures: String, CaseIterable, Identifiable, Sendable {
    /// The font's standard ones ("fi", "fl").
    case standard
    case none
    /// Discretionary ones as well ("ct", "st"), where the font has them.
    case all

    var id: Self { self }

    var name: String {
        switch self {
        case .standard: "Standard"
        case .none: "None"
        case .all: "Standard and Discretionary"
        }
    }
}

/// How the font draws numbers, as InDesign's OpenType menu offers.
enum TextFigures: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case tabularLining, proportionalLining, tabularOldstyle, proportionalOldstyle

    var id: Self { self }

    var name: String {
        switch self {
        case .default: "Default Figure"
        case .tabularLining: "Tabular Lining"
        case .proportionalLining: "Proportional Lining"
        case .tabularOldstyle: "Tabular Oldstyle"
        case .proportionalOldstyle: "Proportional Oldstyle"
        }
    }
}

/// A setting that is on or off, as a choice control.
enum OnOff: String, CaseIterable, Identifiable, Sendable {
    case off, on

    var id: Self { self }

    var name: String {
        switch self {
        case .off: "Off"
        case .on: "On"
        }
    }
}

extension EditingProject {
    /// The text a clip's first Text effect writes, if it has one, for the
    /// clip's name on the timeline: its first line, trimmed.
    func textTitle(of clip: TimelineClip) -> String? {
        guard let content = clip.effects.first(where: { $0.kind == .text })?.text else { return nil }
        let line = content.string.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What a clip resolves to, as `resolvedInfo(for:)` its source does,
    /// with a shape clip named by its text when it has some.
    func resolvedInfo(for clip: TimelineClip) -> ResolvedClipInfo? {
        guard clip.source == .graphic else { return resolvedInfo(for: clip.source) }
        return .graphic(title: textTitle(of: clip))
    }
}
