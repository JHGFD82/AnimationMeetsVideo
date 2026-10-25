import CoreGraphics
import CoreText
import Foundation

/// A block of text as a Text effect sets it at one moment: what is laid
/// out and where its middle is, in the frame's pixels (origin top left,
/// y down). Its outline is its glyphs (see docs/graphic-layers.md, "Text").
struct TextOutline: Equatable, Sendable {
    /// What is laid out, which `TextLayout` keeps the glyphs of.
    struct Setting: Hashable, Sendable {
        var string: String
        var fontName: String
        /// The font's size in pixels.
        var size: Double
        /// Pixels added after each letter.
        var tracking: Double
        /// Percent of the font's own line height.
        var lineHeight: Double
        /// Where lines wrap; 0 sets each paragraph on one line.
        var wrapWidth: Double
        var align: TextAlign
    }

    var setting: Setting
    /// The middle of the block.
    var center: CGPoint

    /// The glyphs' outlines, in the frame's pixels.
    var path: CGPath {
        var move = CGAffineTransform(translationX: center.x, y: center.y)
        let laid = TextLayout.shared.path(for: setting)
        return laid.copy(using: &move) ?? laid
    }

    /// What it draws, in words, for a render's key.
    var keyText: String {
        func n(_ value: Double) -> String { String(format: "%.5f", value) }
        let s = setting
        return "h t\(n(s.size)) \(s.align.rawValue) \(n(s.tracking)) \(n(s.lineHeight)) \(n(s.wrapWidth)) \(n(center.x)),\(n(center.y))"
            + " \(s.fontName) \(s.string.debugDescription)"
    }
}

/// Lays text out with Core Text and keeps the outlines of its glyphs, so a
/// block is set again only when its words or styling change, not for every
/// frame it is drawn in or every place it moves to.
final class TextLayout: @unchecked Sendable {
    static let shared = TextLayout()

    /// Blocks set, by what was set. Cleared whole when full: a size
    /// keyframed over a long clip sets a block per frame, which needn't
    /// all be kept.
    private var laid: [TextOutline.Setting: CGPath] = [:]
    private let lock = NSLock()
    private static let capacity = 256

    /// The outlines of `setting`'s glyphs, with the block's middle at the
    /// origin, y down.
    func path(for setting: TextOutline.Setting) -> CGPath {
        lock.lock()
        if let path = laid[setting] {
            lock.unlock()
            return path
        }
        lock.unlock()
        let path = Self.layOut(setting)
        lock.lock()
        if laid.count >= Self.capacity { laid.removeAll(keepingCapacity: true) }
        laid[setting] = path
        lock.unlock()
        return path
    }

    /// One line as set: its Core Text line, how wide its letters reach, and
    /// whether it ends a paragraph (which a justified block leaves ragged).
    private struct Line {
        var line: CTLine
        var width: Double
        var endsParagraph: Bool
    }

    /// Sets `setting`'s lines one under the next, each paragraph wrapped
    /// at the wrap width (or not at all), and lines them up. The block is
    /// as wide as its wrap width, or its widest line, and as tall as its
    /// lines, centered on the origin.
    static func layOut(_ setting: TextOutline.Setting) -> CGPath {
        let path = CGMutablePath()
        guard setting.size > 0, !setting.string.isEmpty else { return path }
        let font = CTFontCreateWithName(setting.fontName as CFString, setting.size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): setting.tracking,
        ]
        let wraps = setting.wrapWidth > 0
        var lines: [Line] = []
        func measured(_ line: CTLine, endsParagraph: Bool) -> Line {
            let width = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
            // Tracking is added after the last letter too, which isn't part
            // of the line's width.
            let glyphs = CTLineGetGlyphCount(line)
            return Line(line: line, width: max(0, width - (glyphs > 0 ? setting.tracking : 0)), endsParagraph: endsParagraph)
        }
        // "\r\n", "\n" and "\u{2028}" alike start a new line.
        for paragraph in setting.string.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let attributed = NSAttributedString(string: String(paragraph), attributes: attributes)
            guard wraps, attributed.length > 0 else {
                lines.append(measured(CTLineCreateWithAttributedString(attributed), endsParagraph: true))
                continue
            }
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var start = 0
            while start < attributed.length {
                // At least a letter a line, however narrow the wrap.
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, setting.wrapWidth))
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                start += count
                lines.append(measured(line, endsParagraph: start >= attributed.length))
            }
        }

        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let advance = (ascent + descent + CTFontGetLeading(font)) * setting.lineHeight / 100
        let blockWidth = wraps ? setting.wrapWidth : lines.map(\.width).max() ?? 0
        let blockHeight = ascent + descent + advance * Double(max(0, lines.count - 1))
        var baseline = -blockHeight / 2 + ascent
        for var line in lines {
            if setting.align == .justified, wraps, !line.endsParagraph,
               let justified = CTLineCreateJustifiedLine(line.line, 1, blockWidth) {
                line.line = justified
                line.width = blockWidth
            }
            let left: Double = switch setting.align {
            case .left, .justified: -blockWidth / 2
            case .center: -line.width / 2
            case .right: blockWidth / 2 - line.width
            }
            addGlyphs(of: line.line, to: path, origin: CGPoint(x: left, y: baseline))
            baseline += advance
        }
        return path
    }

    /// Adds the outline of every glyph in `line` to `path`, with the line's
    /// baseline starting at `origin`. Core Text's y is up and the frame's
    /// down, so each glyph is flipped. A glyph with no outline (an emoji's
    /// picture) adds nothing.
    private static func addGlyphs(of line: CTLine, to path: CGMutablePath, origin: CGPoint) {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            // A run may fall back to another font for letters the chosen
            // one lacks.
            guard count > 0, let value = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] else { continue }
            let font = value as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                let place = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origin.x + position.x, ty: origin.y - position.y)
                path.addPath(outline, transform: place)
            }
        }
    }
}

/// The fonts installed on this Mac, by family and style, for picking a
/// Text effect's font.
enum FontCatalog {
    /// One style of a family: its PostScript name, which a Text effect
    /// keeps, and what the family calls it ("Bold Italic").
    struct Style: Hashable, Identifiable {
        var fontName: String
        var name: String
        var id: String { fontName }
    }

    /// Every family that can be picked, in alphabetical order. The
    /// system's hidden ones (named with a leading dot) are left out.
    static func families() -> [String] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A family's styles, lightest first, upright before italic.
    static func styles(ofFamily family: String) -> [Style] {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor] ?? []
        let styles = matches.compactMap { match -> (style: Style, weight: Double, slanted: Bool)? in
            guard let name = CTFontDescriptorCopyAttribute(match, kCTFontNameAttribute) as? String else { return nil }
            let styleName = CTFontDescriptorCopyAttribute(match, kCTFontStyleNameAttribute) as? String ?? name
            let traits = CTFontDescriptorCopyAttribute(match, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
            let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            let slanted = symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0
            return (Style(fontName: name, name: styleName), weight, slanted)
        }
        var seen = Set<String>()
        return styles
            .sorted { ($0.weight, $0.slanted ? 1 : 0, $0.style.name) < ($1.weight, $1.slanted ? 1 : 0, $1.style.name) }
            .map(\.style)
            .filter { seen.insert($0.fontName).inserted }
    }

    /// Whether the font named `fontName` is installed. When it isn't, Core
    /// Text draws with a substitute, whose name differs.
    static func isInstalled(_ fontName: String) -> Bool {
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        return CTFontCopyPostScriptName(font) as String == fontName
    }

    /// The family and style of the font named `fontName`, as a Text effect's
    /// font is shown: what Core Text substitutes when it isn't installed.
    static func familyAndStyle(of fontName: String) -> (family: String, style: String) {
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        let family = CTFontCopyFamilyName(font) as String
        let style = CTFontCopyName(font, kCTFontStyleNameKey).map { $0 as String } ?? ""
        return (family, style)
    }

    /// The style of `family` nearest `fontName`'s: the one with the same
    /// style name, or else the first, for when the family is changed.
    static func fontName(inFamily family: String, like fontName: String) -> String? {
        let styles = styles(ofFamily: family)
        let wanted = familyAndStyle(of: fontName).style
        return (styles.first { $0.name == wanted } ?? styles.first { $0.name == "Regular" } ?? styles.first)?.fontName
    }
}
