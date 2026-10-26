import Foundation

/// What some letters of a Text effect set differently from the block (see
/// docs/graphic-layers.md, "Styled runs"). Each setting left nil takes the
/// block's, keyframes and all; one that is set holds for those letters at
/// every moment, so the block's keyframes don't reach them.
struct TextStyle: Hashable, Sendable {
    /// A PostScript name.
    var fontName: String?
    /// Pixels.
    var size: Double?
    /// Thousandths of an em after each letter.
    var tracking: Double?
    /// Pixels up from the baseline.
    var baselineShift: Double?
    /// Percentages.
    var horizontalScale: Double?
    var verticalScale: Double?
    var textCase: TextCase?
    var underline: Bool?
    var strikethrough: Bool?
    /// Red, green, blue and alpha, 0...1: the color the block's fill or
    /// stroke has for these letters, while the block has one.
    var fill: [Double]?
    var stroke: [Double]?
    /// Thousandths of an em between this letter and the next, besides the
    /// font's pair kerning and the tracking: kerning set by hand with the
    /// cursor between the two.
    var kerning: Double?

    static let none = TextStyle()

    var isEmpty: Bool { self == .none }

    /// This style with `other`'s settings over it.
    func merged(with other: TextStyle) -> TextStyle {
        TextStyle(
            fontName: other.fontName ?? fontName, size: other.size ?? size, tracking: other.tracking ?? tracking,
            baselineShift: other.baselineShift ?? baselineShift, horizontalScale: other.horizontalScale ?? horizontalScale,
            verticalScale: other.verticalScale ?? verticalScale, textCase: other.textCase ?? textCase,
            underline: other.underline ?? underline, strikethrough: other.strikethrough ?? strikethrough,
            fill: other.fill ?? fill, stroke: other.stroke ?? stroke, kerning: other.kerning ?? kerning
        )
    }
}

/// Letters of a Text effect's words styled alike: a range of UTF-16 code
/// units, as `NSString` and the text editor count them.
struct TextRun: Hashable, Sendable {
    var start: Int
    var length: Int
    var style: TextStyle

    var end: Int { start + length }
    var range: NSRange { NSRange(location: start, length: length) }
}

extension TextContent {
    /// The words' length in UTF-16 code units, which runs count in.
    var length: Int { (string as NSString).length }

    /// The style of each code unit: what its run sets, or nothing.
    var unitStyles: [TextStyle] {
        var styles = [TextStyle](repeating: .none, count: length)
        for run in runs {
            for unit in max(0, run.start)..<min(length, run.end) where run.start < run.end { styles[unit] = run.style }
        }
        return styles
    }

    /// Runs from one style per code unit: adjacent units styled alike join,
    /// and unstyled ones have none.
    static func runs(from styles: [TextStyle]) -> [TextRun] {
        var runs: [TextRun] = []
        for (unit, style) in styles.enumerated() where !style.isEmpty {
            if var last = runs.last, last.end == unit, last.style == style {
                last.length += 1
                runs[runs.count - 1] = last
            } else {
                runs.append(TextRun(start: unit, length: 1, style: style))
            }
        }
        return runs
    }

    /// What the letter at code unit `index` sets; nothing past the end.
    func style(at index: Int) -> TextStyle {
        runs.first { $0.start <= index && index < $0.end }?.style ?? .none
    }

    /// The letter just before code unit `index`, the first of the pair a
    /// cursor there kerns: nil at either end of the words or of a line.
    func kerningPair(at index: Int) -> NSRange? {
        let text = string as NSString
        guard index > 0, index < text.length else { return nil }
        let before = text.rangeOfComposedCharacterSequence(at: index - 1)
        let after = text.rangeOfComposedCharacterSequence(at: index)
        let isBreak = { (range: NSRange) in text.substring(with: range).contains(where: \.isNewline) }
        return isBreak(before) || isBreak(after) ? nil : before
    }

    /// Changes the style of the letters in `range` (kept to the words) with
    /// `change`.
    mutating func changeStyle(in range: NSRange, _ change: (inout TextStyle) -> Void) {
        var styles = unitStyles
        let lower = max(0, min(range.location, styles.count)), upper = max(lower, min(range.location + range.length, styles.count))
        for unit in lower..<upper { change(&styles[unit]) }
        runs = Self.runs(from: styles)
    }

    /// Replaces the letters in `range` with `replacement`, as typing does,
    /// keeping every other letter's style. What is typed takes the style
    /// of the letter before it, or at the start the one after.
    mutating func replaceCharacters(in range: NSRange, with replacement: String) {
        let text = string as NSString
        let lower = max(0, min(range.location, text.length)), upper = max(lower, min(range.location + range.length, text.length))
        var styles = unitStyles
        let typed = lower > 0 ? styles[lower - 1] : (upper < styles.count ? styles[upper] : .none)
        let count = (replacement as NSString).length
        styles.replaceSubrange(lower..<upper, with: [TextStyle](repeating: typed, count: count))
        string = text.replacingCharacters(in: NSRange(location: lower, length: upper - lower), with: replacement)
        runs = Self.runs(from: styles)
    }

    /// The words changed to `newString` by an edit the text editor made
    /// itself (an undo, a drop), styles kept where the words are unchanged
    /// at either end.
    mutating func replaceString(with newString: String) {
        let old = string as NSString, new = newString as NSString
        var prefix = 0
        while prefix < old.length, prefix < new.length, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < old.length - prefix, suffix < new.length - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        replaceCharacters(
            in: NSRange(location: prefix, length: old.length - prefix - suffix),
            with: new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        )
    }
}
