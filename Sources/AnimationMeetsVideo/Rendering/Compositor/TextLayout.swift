import CoreGraphics
import CoreText
import Foundation

/// Lays text out with Core Text and keeps its glyphs, so a block is set
/// again only when its words or styling change, not for every frame it is
/// drawn in or every place it moves to. Where each glyph then goes, turned
/// or moved, is `TextOutline`'s.
final class TextLayout: @unchecked Sendable {
    static let shared = TextLayout()

    /// How some letters are set: the block's settings with their run's over
    /// them (`TextOutline.Setting.letterStyle`).
    struct LetterStyle: Hashable, Sendable {
        var fontName: String
        var size: Double
        var tracking: Double
        var baselineShift: Double
        var horizontalScale: Double
        var verticalScale: Double
        var textCase: TextCase
        var underline: Bool
        var strikethrough: Bool
        /// The run's colors, nil where the block's are used.
        var fill: [Double]?
        var stroke: [Double]?
        /// Thousandths of an em after the letter, set by hand for the pair
        /// it begins (`TextStyle.kerning`).
        var kerning = 0.0
    }

    /// A block as laid out, in its own space: its top left at the origin,
    /// y down.
    struct Laid: @unchecked Sendable {
        struct Glyph {
            /// Flipped to y down, its baseline's left at the origin, and
            /// scaled as its letter is.
            var outline: CGPath
            /// Where its baseline's left is in the block, baseline shift
            /// included.
            var origin: CGPoint
            var advance: Double
            /// How far above the baseline its font's letters' middle is.
            var middle: Double
            /// Its letter's style, in `styles`.
            var style: Int
            /// Which character, word and line it belongs to, counting from
            /// 0, for an animator's range.
            var character: Int
            var word: Int
            var line: Int
        }

        /// An underline or strikethrough.
        struct Rule {
            var rect: CGRect
            var style: Int
        }

        var glyphs: [Glyph] = []
        var rules: [Rule] = []
        var styles: [LetterStyle] = []
        var size = CGSize.zero
        var characterCount = 0
        var wordCount = 0
        var lineCount = 0
    }

    /// Blocks set, by what was set. Cleared whole when full: a size
    /// keyframed over a long clip sets a block per frame, which needn't
    /// all be kept.
    private var cache: [TextOutline.Setting: Laid] = [:]
    private let lock = NSLock()
    private static let capacity = 256

    /// `setting` laid out, from the cache when it was before.
    func laid(_ setting: TextOutline.Setting) -> Laid {
        lock.lock()
        if let laid = cache[setting] {
            lock.unlock()
            return laid
        }
        lock.unlock()
        let laid = Self.layOut(setting)
        lock.lock()
        if cache.count >= Self.capacity { cache.removeAll(keepingCapacity: true) }
        cache[setting] = laid
        lock.unlock()
        return laid
    }

    /// The attribute naming a letter's style, which Core Text keeps on the
    /// runs it makes.
    private static let styleKey = NSAttributedString.Key("AMVLetterStyle")

    /// One line as set: its Core Text line, how wide its letters reach, its
    /// left indent and the width it may fill (nil when it doesn't wrap),
    /// and where it falls in its paragraph.
    private struct Line {
        var line: CTLine
        var width: Double
        var indent: Double
        var room: Double?
        var startsParagraph: Bool
        var endsParagraph: Bool
        /// Kerning set by hand in the line (`handKerning`).
        var kerning = HandKerning()
    }

    /// The kerning set by hand in one line: how far each letter, by its code
    /// unit, moves along for the pairs before it, and how much wider the
    /// line is for them.
    private struct HandKerning {
        var offsets: [CFIndex: Double] = [:]
        var total = 0.0
    }

    /// The pairs kerned by hand in `line`: each letter's kerning (in
    /// thousandths of its em) moves every letter after it in the line, so
    /// the line's last letter's is left out. Added after Core Text sets the
    /// line, since its tracking puts half its space before a letter; so a
    /// line wraps as if it weren't there.
    private static func handKerning(of line: CTLine, styles: [LetterStyle]) -> HandKerning {
        var letters: [(index: CFIndex, amount: Double)] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0, let styleIndex = (CTRunGetAttributes(run) as NSDictionary)[styleKey.rawValue] as? Int else { continue }
            let style = styles[styleIndex]
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            for index in Set(indices) { letters.append((index, style.kerning / 1000 * style.size)) }
        }
        letters.sort { $0.index < $1.index }
        guard letters.contains(where: { $0.amount != 0 }) else { return HandKerning() }
        // Spaces ending the line don't make a pair with what wraps.
        let lineRange = CTLineGetStringRange(line)
        let visibleEnd = lineRange.location + lineRange.length
        var result = HandKerning()
        for (position, letter) in letters.enumerated() {
            result.offsets[letter.index] = result.total
            if position < letters.count - 1, letter.index < visibleEnd { result.total += letter.amount }
        }
        return result
    }

    /// Sets `setting`'s letters, each in its own style, lines one under the
    /// next, each paragraph wrapped within the wrap width less its indents
    /// (or not at all), and lines them up. The block is as wide as its wrap
    /// width, or its widest line and indents, and as tall as its lines.
    static func layOut(_ setting: TextOutline.Setting) -> Laid {
        var laid = Laid()
        guard setting.size > 0, !setting.string.isEmpty else { return laid }
        let block = setting.letterStyle(.none)
        let content = TextContent(string: setting.string, fontName: setting.fontName, runs: setting.runs)
        var styleIndex: [LetterStyle: Int] = [:]
        // Letters whose styles differ only in color, tracking or rules share
        // one font, so Core Text kerns pairs across them.
        var fonts: [LetterStyle: CTFont] = [:]
        func fontKey(_ style: LetterStyle) -> LetterStyle {
            var key = block
            key.fontName = style.fontName
            key.size = style.size
            key.horizontalScale = style.horizontalScale
            key.verticalScale = style.verticalScale
            key.textCase = style.textCase
            return key
        }
        func index(of style: LetterStyle) -> Int {
            if let index = styleIndex[style] { return index }
            laid.styles.append(style)
            styleIndex[style] = laid.styles.count - 1
            return laid.styles.count - 1
        }
        func font(of style: LetterStyle) -> CTFont {
            let key = fontKey(style)
            if let font = fonts[key] { return font }
            let font = Self.font(for: setting, style: key)
            fonts[key] = font
            return font
        }

        // The letters as drawn, each with its style.
        let display = NSMutableAttributedString()
        let source = setting.string as NSString
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byComposedCharacterSequences) { letter, range, _, _ in
            guard var letter else { return }
            let style = setting.letterStyle(content.style(at: range.location))
            if style.textCase == .allCaps { letter = letter.uppercased() }
            display.append(NSAttributedString(string: letter, attributes: attributes(font(of: style), style, index(of: style), setting)))
        }

        // Paragraphs, and which character and word each code unit is in.
        let text = display.string as NSString
        var paragraphs: [NSRange] = []
        var characters = [Int](repeating: 0, count: text.length), words = characters
        var paragraphStart = 0, character = -1, word = -1, inWord = false
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byComposedCharacterSequences) { letter, range, _, _ in
            let letter = letter ?? ""
            if letter.contains(where: \.isNewline) {
                paragraphs.append(NSRange(location: paragraphStart, length: range.location - paragraphStart))
                paragraphStart = range.location + range.length
                inWord = false
                return
            }
            character += 1
            let isSpace = letter.allSatisfy(\.isWhitespace)
            if !isSpace, !inWord { word += 1 }
            inWord = !isSpace
            for unit in range.location..<(range.location + range.length) {
                characters[unit] = character
                words[unit] = max(0, word)
            }
        }
        paragraphs.append(NSRange(location: paragraphStart, length: text.length - paragraphStart))
        laid.characterCount = character + 1
        laid.wordCount = word + 1

        let wraps = setting.wrapWidth > 0
        var lines: [Line] = []
        for paragraph in paragraphs {
            let attributed = display.attributedSubstring(from: paragraph)
            let firstIndent = setting.leftIndent + setting.firstLineIndent
            guard wraps, attributed.length > 0 else {
                // An empty paragraph still takes a line, in the block's font.
                let line = attributed.length > 0
                    ? CTLineCreateWithAttributedString(attributed)
                    : CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: attributes(font(of: block), block, index(of: block), setting)))
                let room = wraps ? max(1, setting.wrapWidth - firstIndent - setting.rightIndent) : nil
                lines.append(Line(line: line, width: width(of: line), indent: firstIndent, room: room, startsParagraph: true, endsParagraph: true))
                continue
            }
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var start = 0
            while start < attributed.length {
                let indent = start == 0 ? firstIndent : setting.leftIndent
                let room = max(1, setting.wrapWidth - indent - setting.rightIndent)
                // At least a letter a line, however narrow the room.
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, room))
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                lines.append(Line(
                    line: line, width: width(of: line), indent: indent, room: room,
                    startsParagraph: start == 0, endsParagraph: start + count >= attributed.length
                ))
                start += count
            }
        }
        laid.lineCount = lines.count
        // Kerning set by hand widens its line.
        for index in lines.indices {
            lines[index].kerning = handKerning(of: lines[index].line, styles: laid.styles)
            lines[index].width += lines[index].kerning.total
        }

        // Each line's height and spacing from its own letters.
        func metrics(of line: CTLine) -> (ascent: Double, descent: Double, size: Double) {
            var result = (ascent: 0.0, descent: 0.0, size: 0.0)
            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            for run in runs {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let style = (attributes[styleKey.rawValue] as? Int).map({ laid.styles[$0] }),
                      let value = attributes[kCTFontAttributeName as String] else { continue }
                let runFont = value as! CTFont
                result.ascent = max(result.ascent, CTFontGetAscent(runFont))
                result.descent = max(result.descent, CTFontGetDescent(runFont))
                result.size = max(result.size, style.size)
            }
            if runs.isEmpty {
                let blockFont = font(of: block)
                result = (CTFontGetAscent(blockFont), CTFontGetDescent(blockFont), block.size)
            }
            return result
        }
        let lineMetrics = lines.map { metrics(of: $0.line) }
        let blockWidth = wraps
            ? setting.wrapWidth
            : lines.map { $0.indent + $0.width + setting.rightIndent }.max() ?? 0
        var baselines: [Double] = []
        var baseline = lineMetrics.first?.ascent ?? 0
        for (index, line) in lines.enumerated() {
            if index > 0 {
                baseline += setting.leading > 0 ? setting.leading : lineMetrics[index].size * 1.2
                if line.startsParagraph { baseline += setting.spaceAfter + setting.spaceBefore }
            }
            baselines.append(baseline)
        }
        laid.size = CGSize(width: blockWidth, height: baseline + (lineMetrics.last?.descent ?? 0))

        for (number, (var line, lineBaseline)) in zip(lines, baselines).enumerated() {
            let room = line.room ?? (blockWidth - line.indent - setting.rightIndent)
            var align = line.endsParagraph ? setting.align.lastLine : setting.align
            if align.isJustified {
                if wraps, let justified = CTLineCreateJustifiedLine(line.line, 1, room - line.kerning.total) {
                    line.line = justified
                    line.width = room
                }
                align = .left
            }
            let start: Double = switch align {
            case .center: line.indent + (room - line.width) / 2
            case .right: line.indent + room - line.width
            default: line.indent
            }
            addGlyphs(of: line, number: number, at: CGPoint(x: start, y: lineBaseline), to: &laid, characters: characters, words: words)
        }
        return laid
    }

    /// The attributes a letter is set with: its font, tracking, the
    /// block's kerning and ligatures, and its style's index.
    private static func attributes(_ font: CTFont, _ style: LetterStyle, _ index: Int, _ setting: TextOutline.Setting) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            key(kCTFontAttributeName): font,
            // Tracking leaves the font's kerning pairs as they are.
            key(kCTTrackingAttributeName): style.tracking / 1000 * style.size,
            styleKey: index,
        ]
        // A kern of 0 turns the font's pairs off; its OpenType 'kern'
        // feature, off, doesn't.
        if setting.kerning == .none { attributes[key(kCTKernAttributeName)] = 0 }
        switch setting.ligatures {
        // Only those a script can't be written without.
        case .none: attributes[key(kCTLigatureAttributeName)] = 0
        case .all: attributes[key(kCTLigatureAttributeName)] = 2
        case .standard: break
        }
        return attributes
    }

    private static func key(_ name: CFString) -> NSAttributedString.Key { NSAttributedString.Key(name as String) }

    /// How wide a line's letters reach: its typographic width less the
    /// spaces it ends with and the tracking after its last letter.
    private static func width(of line: CTLine) -> Double {
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], let last = runs.last,
              let tracking = (CTRunGetAttributes(last) as NSDictionary)[kCTTrackingAttributeName as String] as? Double,
              CTLineGetTrailingWhitespaceWidth(line) == 0
        else { return max(0, width) }
        return max(0, width - tracking)
    }

    /// The font named in `setting` at its size, with the OpenType features
    /// its settings ask for. Core Text keeps only those the font has, so a
    /// font without one draws as if it were off.
    static func font(for setting: TextOutline.Setting) -> CTFont {
        font(for: setting, style: setting.letterStyle(.none))
    }

    /// The font of letters set in `style`: its scale as the font's matrix,
    /// so Core Text measures, wraps and draws them scaled.
    static func font(for setting: TextOutline.Setting, style: LetterStyle) -> CTFont {
        var matrix = CGAffineTransform(scaleX: style.horizontalScale / 100, y: style.verticalScale / 100)
        let base = CTFontCreateWithName(style.fontName as CFString, style.size, &matrix)
        let features = openTypeFeatures(for: setting, textCase: style.textCase).map { feature -> [CFString: Any] in
            [kCTFontOpenTypeFeatureTag: feature.tag, kCTFontOpenTypeFeatureValue: feature.on ? 1 : 0]
        }
        guard !features.isEmpty else { return base }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: features] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, style.size, &matrix, descriptor)
    }

    /// The OpenType features `setting`'s Case and OpenType settings turn on
    /// or off, by tag ("smcp"), in order; none while all are as the font
    /// has them.
    static func openTypeFeatures(for setting: TextOutline.Setting) -> [(tag: String, on: Bool)] {
        openTypeFeatures(for: setting, textCase: setting.textCase)
    }

    static func openTypeFeatures(for setting: TextOutline.Setting, textCase: TextCase) -> [(tag: String, on: Bool)] {
        var features: [(tag: String, on: Bool)] = []
        func feature(_ tag: String, _ on: Bool) { features.append((tag, on)) }
        if textCase == .smallCaps || textCase == .allSmallCaps { feature("smcp", true) }
        if textCase == .allSmallCaps { feature("c2sc", true) }
        switch setting.ligatures {
        case .none:
            feature("liga", false)
            feature("clig", false)
        case .all: feature("dlig", true)
        case .standard: break
        }
        if !setting.contextualAlternates { feature("calt", false) }
        switch setting.figures {
        case .default: break
        case .tabularLining: feature("tnum", true); feature("lnum", true)
        case .proportionalLining: feature("pnum", true); feature("lnum", true)
        case .tabularOldstyle: feature("tnum", true); feature("onum", true)
        case .proportionalOldstyle: feature("pnum", true); feature("onum", true)
        }
        if setting.fractions { feature("frac", true) }
        if setting.ordinals { feature("ordn", true) }
        if setting.swash { feature("swsh", true) }
        if setting.stylisticAlternates { feature("salt", true) }
        if (1...20).contains(setting.stylisticSet) { feature(String(format: "ss%02d", setting.stylisticSet), true) }
        return features
    }

    /// Adds every glyph of `line`, its baseline starting at `origin`, to
    /// `laid`, and its runs' underlines and strikethroughs. A glyph with no
    /// outline (an emoji's picture) adds nothing.
    private static func addGlyphs(of line: Line, number: Int, at origin: CGPoint, to laid: inout Laid, characters: [Int], words: [Int]) {
        guard let runs = CTLineGetGlyphRuns(line.line) as? [CTRun] else { return }
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        /// Where the next run starts along the line.
        var pen: Double?
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            // A run may fall back to another font for letters the chosen
            // one lacks; it keeps its letters' style.
            guard count > 0, let value = attributes[kCTFontAttributeName as String],
                  let styleIndex = attributes[styleKey.rawValue] as? Int else { continue }
            let font = value as! CTFont
            let style = laid.styles[styleIndex]
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            // A run's positions and advances leave out its font's matrix
            // (its letters' scale), which its outlines and the line's
            // widths have: each run is scaled and set where the runs before
            // it end.
            let matrix = CTRunGetTextMatrix(run)
            let firstX = positions.first?.x ?? 0
            if pen == nil { pen = firstX }
            let runStart = pen ?? 0
            for k in 0..<count {
                let kerned = line.kerning.offsets[indices[k]] ?? 0
                positions[k] = CGPoint(x: runStart + (positions[k].x - firstX) * matrix.a + kerned, y: positions[k].y * matrix.d)
                advances[k].width *= matrix.a
            }
            pen = runStart + advances.reduce(0) { $0 + $1.width }
            let middle = (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2
            for k in 0..<count {
                guard var outline = CTFontCreatePathForGlyph(font, glyphs[k], nil) else { continue }
                outline = outline.copy(using: [flip]) ?? outline
                let unit = indices[k]
                laid.glyphs.append(Laid.Glyph(
                    outline: outline,
                    origin: CGPoint(x: origin.x + positions[k].x, y: origin.y - positions[k].y - style.baselineShift),
                    advance: advances[k].width, middle: middle, style: styleIndex,
                    character: characters.indices.contains(unit) ? characters[unit] : 0,
                    word: words.indices.contains(unit) ? words[unit] : 0, line: number
                ))
            }
            guard style.underline || style.strikethrough, let first = positions.first, let lastIndex = positions.indices.last else { continue }
            // As far as the run's letters reach, not the spaces ending a line.
            let left = origin.x + first.x
            let right = min(origin.x + positions[lastIndex].x + advances[lastIndex].width, origin.x + line.width)
            guard right > left else { continue }
            let given = CTFontGetUnderlineThickness(font)
            let thickness = given > 0 ? given : style.size / 20
            let baseline = origin.y - style.baselineShift
            func rule(atHeight height: Double) {
                laid.rules.append(Laid.Rule(
                    rect: CGRect(x: left, y: baseline - height - thickness / 2, width: right - left, height: thickness), style: styleIndex
                ))
            }
            if style.underline { rule(atHeight: CTFontGetUnderlinePosition(font)) }
            if style.strikethrough { rule(atHeight: CTFontGetXHeight(font) / 2) }
        }
    }
}
