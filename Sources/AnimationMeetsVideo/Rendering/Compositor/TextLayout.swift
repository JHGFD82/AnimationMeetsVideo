import CoreGraphics
import CoreMedia
import CoreText
import Foundation

/// A block of text as a Text effect sets it at one moment: what is laid
/// out and where its middle is, in the frame's pixels (origin top left,
/// y down). Its outline is its glyphs (see docs/graphic-layers.md, "Text").
struct TextOutline: Equatable, Sendable {
    /// What is laid out, which `TextLayout` keeps the glyphs of: the words
    /// and font, and the settings of Illustrator's Character, Paragraph and
    /// OpenType panels, each for the whole block. Lengths are in pixels.
    struct Setting: Hashable, Sendable {
        var string: String
        var fontName: String
        var size: Double

        // Character
        /// Baseline to baseline; 0 is Auto, 120% of the size.
        var leading = 0.0
        var kerning = TextKerning.metrics
        /// Thousandths of an em added after each letter.
        var tracking = 0.0
        /// Percentages of the letters' height and width.
        var verticalScale = 100.0
        var horizontalScale = 100.0
        /// Up from the baseline.
        var baselineShift = 0.0
        /// Degrees each letter turns about its middle, clockwise.
        var characterRotation = 0.0
        var textCase = TextCase.normal
        var underline = false
        var strikethrough = false

        // Paragraph
        var align = TextAlign.center
        var leftIndent = 0.0
        var rightIndent = 0.0
        /// Added to a paragraph's first line's left indent; below 0 hangs it.
        var firstLineIndent = 0.0
        /// Added between paragraphs: after one, before the next.
        var spaceBefore = 0.0
        var spaceAfter = 0.0
        /// Where lines wrap; 0 sets each paragraph on one line.
        var wrapWidth = 0.0

        // OpenType
        var ligatures = TextLigatures.standard
        var contextualAlternates = true
        var figures = TextFigures.default
        var fractions = false
        var ordinals = false
        var swash = false
        var stylisticAlternates = false
        /// ss01 to ss20; 0 for none.
        var stylisticSet = 0

        /// What a Text effect sets at source time `time`: each control
        /// that is on at its value there, one that is off or deleted at its
        /// default. Nil with no words or no size.
        init?(_ effect: Effect, at time: CMTime) {
            func number(_ kind: ControlKind) -> Double {
                guard let control = effect.control(kind), control.enabled else { return kind.defaultValues.first ?? 0 }
                return control.values(at: time).first ?? 0
            }
            func choice<Option: RawRepresentable>(_ kind: ControlKind, _ fallback: Option) -> Option where Option.RawValue == String {
                let picked = effect.control(kind).flatMap { $0.enabled ? $0.choice : nil } ?? kind.defaultChoice
                return picked.flatMap(Option.init(rawValue:)) ?? fallback
            }
            func isOn(_ kind: ControlKind) -> Bool { choice(kind, OnOff.off) == .on }
            let size = number(.fontSize)
            guard let content = effect.text, !content.string.isEmpty, size > 0 else { return nil }
            self.init(string: content.string, fontName: content.fontName, size: size)
            leading = max(0, number(.leading))
            kerning = choice(.kerning, .metrics)
            tracking = number(.tracking)
            verticalScale = max(1, number(.verticalScale))
            horizontalScale = max(1, number(.horizontalScale))
            baselineShift = number(.baselineShift)
            characterRotation = number(.characterRotation)
            textCase = choice(.textCase, .normal)
            underline = isOn(.underline)
            strikethrough = isOn(.strikethrough)
            align = choice(.textAlign, .center)
            leftIndent = max(0, number(.leftIndent))
            rightIndent = max(0, number(.rightIndent))
            firstLineIndent = number(.firstLineIndent)
            spaceBefore = max(0, number(.spaceBefore))
            spaceAfter = max(0, number(.spaceAfter))
            wrapWidth = max(0, number(.wrapWidth))
            ligatures = choice(.ligatures, .standard)
            contextualAlternates = isOn(.contextualAlternates)
            figures = choice(.figures, .default)
            fractions = isOn(.fractions)
            ordinals = isOn(.ordinals)
            swash = isOn(.swash)
            stylisticAlternates = isOn(.stylisticAlternates)
            stylisticSet = Int(ControlKind.stylisticSet.clamped(number(.stylisticSet)))
        }

        init(string: String, fontName: String, size: Double) {
            self.string = string
            self.fontName = fontName
            self.size = size
        }

        /// Baseline to baseline: as set, or Auto's 120% of the size.
        var lineAdvance: Double { leading > 0 ? leading : size * 1.2 }
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

    /// What it draws, in words, for a render's key: every setting, which
    /// a new one joins without being listed here.
    var keyText: String {
        "h t \(String(describing: setting)) \(String(format: "%.5f,%.5f", center.x, center.y))"
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

    /// One line as set, before horizontal scale: its Core Text line, how
    /// wide its letters reach, its left indent and the width it may fill
    /// (nil when it doesn't wrap), and where it falls in its paragraph.
    private struct Line {
        var line: CTLine
        var width: Double
        var indent: Double
        var room: Double?
        var startsParagraph: Bool
        var endsParagraph: Bool
    }

    /// Sets `setting`'s lines one under the next, each paragraph wrapped
    /// within the wrap width less its indents (or not at all), lines them
    /// up, and draws each glyph scaled, shifted and turned. The block is as
    /// wide as its wrap width, or its widest line and indents, and as tall
    /// as its lines, centered on the origin.
    static func layOut(_ setting: TextOutline.Setting) -> CGPath {
        let path = CGMutablePath()
        guard setting.size > 0, !setting.string.isEmpty else { return path }
        let font = font(for: setting)
        let wide = setting.horizontalScale / 100, tall = setting.verticalScale / 100
        var attributes: [NSAttributedString.Key: Any] = [
            key(kCTFontAttributeName): font,
            // Tracking leaves the font's kerning pairs as they are.
            key(kCTTrackingAttributeName): setting.tracking / 1000 * setting.size,
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
        let string = setting.textCase == .allCaps ? setting.string.uppercased() : setting.string
        let wraps = setting.wrapWidth > 0
        var lines: [Line] = []
        // "\r\n", "\n" and "\u{2028}" alike start a new line.
        for paragraph in string.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let attributed = NSAttributedString(string: String(paragraph), attributes: attributes)
            let firstIndent = setting.leftIndent + setting.firstLineIndent
            guard wraps, attributed.length > 0 else {
                let line = CTLineCreateWithAttributedString(attributed)
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
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, room / wide))
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                lines.append(Line(
                    line: line, width: width(of: line), indent: indent, room: room,
                    startsParagraph: start == 0, endsParagraph: start + count >= attributed.length
                ))
                start += count
            }
        }

        let ascent = CTFontGetAscent(font) * tall, descent = CTFontGetDescent(font) * tall
        let blockWidth = wraps
            ? setting.wrapWidth
            : lines.map { $0.indent + $0.width * wide + setting.rightIndent }.max() ?? 0
        var baseline = ascent
        var baselines: [Double] = []
        for (index, line) in lines.enumerated() {
            if index > 0 {
                baseline += setting.lineAdvance
                if line.startsParagraph { baseline += setting.spaceAfter + setting.spaceBefore }
            }
            baselines.append(baseline)
        }
        let top = -(baseline + descent) / 2
        let left = -blockWidth / 2
        for (var line, lineBaseline) in zip(lines, baselines) {
            let room = line.room ?? (blockWidth - line.indent - setting.rightIndent)
            var align = line.endsParagraph ? setting.align.lastLine : setting.align
            if align.isJustified {
                if wraps, let justified = CTLineCreateJustifiedLine(line.line, 1, room / wide) {
                    line.line = justified
                    line.width = room / wide
                }
                align = .left
            }
            let shown = line.width * wide
            let start: Double = switch align {
            case .center: line.indent + (room - shown) / 2
            case .right: line.indent + room - shown
            default: line.indent
            }
            let origin = CGPoint(x: left + start, y: top + lineBaseline - setting.baselineShift)
            addGlyphs(of: line.line, to: path, origin: origin, setting: setting, font: font)
            addRules(under: shown, at: origin, to: path, setting: setting, font: font)
        }
        return path
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
        let features = openTypeFeatures(for: setting).map { feature -> [CFString: Any] in
            [kCTFontOpenTypeFeatureTag: feature.tag, kCTFontOpenTypeFeatureValue: feature.on ? 1 : 0]
        }
        let base = CTFontCreateWithName(setting.fontName as CFString, setting.size, nil)
        guard !features.isEmpty else { return base }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: features] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, setting.size, nil, descriptor)
    }

    /// The OpenType features `setting`'s Case and OpenType settings turn on
    /// or off, by tag ("smcp"), in order; none while all are as the font
    /// has them.
    static func openTypeFeatures(for setting: TextOutline.Setting) -> [(tag: String, on: Bool)] {
        var features: [(tag: String, on: Bool)] = []
        func feature(_ tag: String, _ on: Bool) { features.append((tag, on)) }
        if setting.textCase == .smallCaps || setting.textCase == .allSmallCaps { feature("smcp", true) }
        if setting.textCase == .allSmallCaps { feature("c2sc", true) }
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

    /// Adds the outline of every glyph in `line` to `path`, with the line's
    /// baseline starting at `origin`: each scaled as the setting says, then
    /// turned about the middle of its advance. Core Text's y is up and the
    /// frame's down, so each glyph is flipped. A glyph with no outline (an
    /// emoji's picture) adds nothing.
    private static func addGlyphs(of line: CTLine, to path: CGMutablePath, origin: CGPoint, setting: TextOutline.Setting, font: CTFont) {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        let wide = setting.horizontalScale / 100, tall = setting.verticalScale / 100
        let turn = -setting.characterRotation * .pi / 180
        // Halfway up the letters, in Core Text's y.
        let middle = (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2 * tall
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            // A run may fall back to another font for letters the chosen
            // one lacks.
            guard count > 0, let value = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] else { continue }
            let runFont = value as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            for k in 0..<count {
                guard let outline = CTFontCreatePathForGlyph(runFont, glyphs[k], nil) else { continue }
                var place = CGAffineTransform(scaleX: wide, y: tall)
                if turn != 0 {
                    let pivot = CGPoint(x: advances[k].width * wide / 2, y: middle)
                    place = place
                        .concatenating(CGAffineTransform(translationX: -pivot.x, y: -pivot.y))
                        .concatenating(CGAffineTransform(rotationAngle: turn))
                        .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y))
                }
                place = place.concatenating(CGAffineTransform(
                    a: 1, b: 0, c: 0, d: -1, tx: origin.x + positions[k].x * wide, ty: origin.y - positions[k].y * tall
                ))
                path.addPath(outline, transform: place)
            }
        }
    }

    /// Adds the setting's underline and strikethrough under a line `width`
    /// wide starting at `origin`, as thick as the font says an underline
    /// is: the underline where the font puts it, the strikethrough half the
    /// x-height up.
    private static func addRules(under width: Double, at origin: CGPoint, to path: CGMutablePath, setting: TextOutline.Setting, font: CTFont) {
        guard width > 0, setting.underline || setting.strikethrough else { return }
        let tall = setting.verticalScale / 100
        let given = CTFontGetUnderlineThickness(font)
        let thickness = (given > 0 ? given : setting.size / 20) * tall
        func rule(atHeight height: Double) {
            path.addRect(CGRect(x: origin.x, y: origin.y - height - thickness / 2, width: width, height: thickness))
        }
        if setting.underline { rule(atHeight: CTFontGetUnderlinePosition(font) * tall) }
        if setting.strikethrough { rule(atHeight: CTFontGetXHeight(font) / 2 * tall) }
    }
}
