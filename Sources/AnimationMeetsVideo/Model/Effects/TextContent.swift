import CoreGraphics
import CoreMedia
import Foundation

/// What a Text effect writes, which isn't a control: the words and the
/// font they are set in (see docs/graphic-layers.md, "Text"). Its size,
/// alignment, tracking, line height and wrap width are controls, so they
/// can be keyframed like any other.
struct TextContent: Equatable, Sendable {
    /// The words, with a line break for each new line.
    var string = "Text"
    /// The font's PostScript name, which names one style of one family
    /// ("HelveticaNeue-Bold"). Kept even when the font isn't installed,
    /// which then draws with a substitute (see `FontCatalog.isInstalled`).
    var fontName = TextContent.defaultFontName

    /// A heavy sans serif every Mac has.
    static let defaultFontName = "HelveticaNeue-Bold"
}

/// How the lines of a text block line up with each other.
enum TextAlign: String, CaseIterable, Identifiable, Sendable {
    case left, center, right
    /// Every line of a wrapped paragraph but its last spans the wrap width;
    /// the last, and unwrapped text, line up on the left.
    case justified

    var id: Self { self }

    var name: String {
        switch self {
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .justified: "Justified"
        }
    }

    var systemImage: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify"
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
