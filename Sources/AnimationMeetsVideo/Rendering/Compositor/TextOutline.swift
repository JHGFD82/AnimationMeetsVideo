import CoreGraphics
import CoreMedia
import Foundation

/// A block of text as a Text effect sets it at one moment: what is laid
/// out and where its middle is, in the frame's pixels (origin top left,
/// y down). Its outline is its glyphs (see docs/graphic-layers.md, "Text").
struct TextOutline: Equatable, Sendable {
    /// What is laid out, which `TextLayout` keeps the glyphs of: the words
    /// and font, the settings of Illustrator's Character, Paragraph and
    /// OpenType panels for the whole block, and the runs of letters styled
    /// apart from it. Lengths are in pixels.
    struct Setting: Hashable, Sendable {
        var string: String
        var fontName: String
        var size: Double

        // Character
        /// Baseline to baseline; 0 is Auto, 120% of a line's largest size.
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

        /// Letters styled apart from the block (`TextContent.runs`).
        var runs: [TextRun] = []

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
            runs = content.runs
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

        /// How the letters a run styles are set: the run's settings, and
        /// the block's where it has none.
        func letterStyle(_ style: TextStyle) -> TextLayout.LetterStyle {
            TextLayout.LetterStyle(
                fontName: style.fontName ?? fontName, size: max(0.01, style.size ?? size), tracking: style.tracking ?? tracking,
                baselineShift: style.baselineShift ?? baselineShift,
                horizontalScale: max(1, style.horizontalScale ?? horizontalScale), verticalScale: max(1, style.verticalScale ?? verticalScale),
                textCase: style.textCase ?? textCase, underline: style.underline ?? underline,
                strikethrough: style.strikethrough ?? strikethrough, fill: style.fill, stroke: style.stroke,
                kerning: style.kerning ?? 0
            )
        }
    }

    /// Letters drawn alike: their outline, in the frame's pixels, and the
    /// colors and opacity they are filled and stroked with.
    struct Piece {
        var path: CGPath
        /// Nil while the block has no fill, or no stroke.
        var fill: [Double]?
        var stroke: [Double]?
        var opacity = 1.0
    }

    var setting: Setting
    /// The middle of the block.
    var center: CGPoint

    /// The glyphs' outlines, in the frame's pixels.
    var path: CGPath {
        let path = CGMutablePath()
        for piece in pieces(fill: nil, stroke: nil) { path.addPath(piece.path) }
        return path
    }

    /// The block's letters and rules placed in the frame, grouped by how
    /// they are drawn: each run's colors over the block's `fill` and
    /// `stroke`, where the block has them.
    func pieces(fill: [Double]?, stroke: [Double]?) -> [Piece] {
        let laid = TextLayout.shared.laid(setting)
        let turn = setting.characterRotation * .pi / 180
        let toFrame = CGAffineTransform(translationX: center.x - laid.size.width / 2, y: center.y - laid.size.height / 2)
        var paths = laid.styles.map { _ in CGMutablePath() }
        for glyph in laid.glyphs {
            var place = CGAffineTransform.identity
            if turn != 0 {
                let pivot = CGPoint(x: glyph.advance / 2, y: -glyph.middle)
                place = CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
                    .concatenating(CGAffineTransform(rotationAngle: turn))
                    .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y))
            }
            place = place.concatenating(CGAffineTransform(translationX: glyph.origin.x, y: glyph.origin.y)).concatenating(toFrame)
            paths[glyph.style].addPath(glyph.outline, transform: place)
        }
        for rule in laid.rules {
            paths[rule.style].addRect(rule.rect, transform: toFrame)
        }
        return zip(laid.styles, paths).compactMap { style, path in
            guard !path.isEmpty else { return nil }
            return Piece(path: path, fill: fill.map { style.fill ?? $0 }, stroke: stroke.map { style.stroke ?? $0 })
        }
    }

    /// What it draws, in words, for a render's key: every setting, which
    /// a new one joins without being listed here.
    var keyText: String {
        "h t \(String(describing: setting)) \(String(format: "%.5f,%.5f", center.x, center.y))"
    }
}
