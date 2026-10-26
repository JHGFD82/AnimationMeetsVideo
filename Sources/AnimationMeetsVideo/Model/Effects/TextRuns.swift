import CoreMedia
import Foundation

/// What some letters of a Text effect set differently from the block at
/// one moment (`TextRunStyle.at`), as their letters are laid out. Each
/// setting left nil takes the block's.
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
    /// Red, green, blue and alpha, 0...1: the color these letters are
    /// filled or stroked with, whether or not the block's fill or stroke is
    /// on.
    var fill: [Double]?
    var stroke: [Double]?
    /// Thousandths of an em between this letter and the next, besides the
    /// font's pair kerning and the tracking: kerning set by hand with the
    /// cursor between the two.
    var kerning: Double?
    /// Superscript or subscript.
    var position: TextPosition?
    /// Pixels; the stroke's other settings are the block's.
    var strokeWidth: Double?

    static let none = TextStyle()

    var isEmpty: Bool { self == .none }
}

/// What some letters of a Text effect set differently from the block (see
/// docs/graphic-layers.md, "Styled runs"), as kept: each number and color
/// a value that can be keyframed in the clip's source time, as the block's
/// controls are. Each setting left nil takes the block's, keyframes and
/// all; one that is set replaces the block's for its letters, its own
/// keyframes with it, so the block's keyframes don't reach them.
struct TextRunStyle: Equatable, Sendable {
    var fontName: String?
    var size: AnimatedValue<Double>?
    var tracking: AnimatedValue<Double>?
    var baselineShift: AnimatedValue<Double>?
    var horizontalScale: AnimatedValue<Double>?
    var verticalScale: AnimatedValue<Double>?
    var textCase: TextCase?
    var underline: Bool?
    var strikethrough: Bool?
    var fill: AnimatedValue<ComponentValue>?
    var stroke: AnimatedValue<ComponentValue>?
    var kerning: AnimatedValue<Double>?
    var position: TextPosition?
    var strokeWidth: AnimatedValue<Double>?

    static let none = TextRunStyle()

    var isEmpty: Bool { self == .none }

    /// The settings that are numbers, for editing and easing them alike.
    static var numbers: [WritableKeyPath<TextRunStyle, AnimatedValue<Double>?>] {
        [\.size, \.tracking, \.baselineShift, \.horizontalScale, \.verticalScale, \.kerning, \.strokeWidth]
    }
    /// The settings that are colors.
    static var colors: [WritableKeyPath<TextRunStyle, AnimatedValue<ComponentValue>?>] { [\.fill, \.stroke] }

    init() {}

    /// A style holding `style`'s settings still.
    init(fixed style: TextStyle) {
        fontName = style.fontName
        size = style.size.map { AnimatedValue($0) }
        tracking = style.tracking.map { AnimatedValue($0) }
        baselineShift = style.baselineShift.map { AnimatedValue($0) }
        horizontalScale = style.horizontalScale.map { AnimatedValue($0) }
        verticalScale = style.verticalScale.map { AnimatedValue($0) }
        textCase = style.textCase
        underline = style.underline
        strikethrough = style.strikethrough
        fill = style.fill.map { AnimatedValue(ComponentValue(values: $0)) }
        stroke = style.stroke.map { AnimatedValue(ComponentValue(values: $0)) }
        kerning = style.kerning.map { AnimatedValue($0) }
        position = style.position
        strokeWidth = style.strokeWidth.map { AnimatedValue($0) }
    }

    /// Its settings at source time `time`.
    func at(_ time: CMTime) -> TextStyle {
        TextStyle(
            fontName: fontName, size: size?.value(at: time), tracking: tracking?.value(at: time),
            baselineShift: baselineShift?.value(at: time), horizontalScale: horizontalScale?.value(at: time),
            verticalScale: verticalScale?.value(at: time), textCase: textCase, underline: underline, strikethrough: strikethrough,
            fill: fill?.value(at: time).values, stroke: stroke?.value(at: time).values, kerning: kerning?.value(at: time),
            position: position, strokeWidth: strokeWidth?.value(at: time)
        )
    }

    /// The spans in which any of its settings is between keyframes.
    var animatedRanges: [ClosedRange<CMTime>] {
        Self.numbers.compactMap { self[keyPath: $0]?.animatedRange } + Self.colors.compactMap { self[keyPath: $0]?.animatedRange }
    }

    /// Applies an ease to every keyframe its settings have at `time`.
    /// Returns whether there was one.
    mutating func applyEase(_ preset: KeyframeEase.Preset, at time: CMTime) -> Bool {
        var eased = false
        for path in Self.numbers where self[keyPath: path]?.keyframe(at: time) != nil {
            self[keyPath: path]?.applyEase(preset, at: time)
            eased = true
        }
        for path in Self.colors where self[keyPath: path]?.keyframe(at: time) != nil {
            self[keyPath: path]?.applyEase(preset, at: time)
            eased = true
        }
        return eased
    }
}

/// A setting of some letters that can be keyframed: the numbers and colors
/// of `TextRunStyle`. The inspector gives letters their own of one; the
/// effects panel keyframes it.
enum TextRunSetting: String, CaseIterable, Hashable, Sendable {
    case size, tracking, kerning, baselineShift, verticalScale, horizontalScale, fill, stroke, strokeWidth

    var name: String {
        switch self {
        case .size: "Size"
        case .tracking: "Tracking"
        case .kerning: "Kerning"
        case .baselineShift: "Baseline Shift"
        case .verticalScale: "Vertical Scale"
        case .horizontalScale: "Horizontal Scale"
        case .fill: "Fill"
        case .stroke: "Stroke"
        case .strokeWidth: "Stroke Width"
        }
    }

    var unit: String {
        switch self {
        case .size, .baselineShift, .strokeWidth: " px"
        case .verticalScale, .horizontalScale: "%"
        case .tracking, .kerning, .fill, .stroke: ""
        }
    }

    /// What each component is limited to: the inspector's limits.
    var range: ClosedRange<Double> {
        switch self {
        case .size, .verticalScale, .horizontalScale: 1...10_000
        case .tracking, .kerning: -1000...10_000
        case .baselineShift: -100_000...100_000
        case .strokeWidth: 0...10_000
        case .fill, .stroke: 0...1
        }
    }

    var isColor: Bool { self == .fill || self == .stroke }

    var componentNames: [String] { isColor ? ["Red", "Green", "Blue", "Alpha"] : [name] }

    var number: WritableKeyPath<TextRunStyle, AnimatedValue<Double>?>? {
        switch self {
        case .size: \.size
        case .tracking: \.tracking
        case .kerning: \.kerning
        case .baselineShift: \.baselineShift
        case .verticalScale: \.verticalScale
        case .horizontalScale: \.horizontalScale
        case .strokeWidth: \.strokeWidth
        case .fill, .stroke: nil
        }
    }

    var color: WritableKeyPath<TextRunStyle, AnimatedValue<ComponentValue>?>? {
        switch self {
        case .fill: \.fill
        case .stroke: \.stroke
        default: nil
        }
    }
}

extension TextRunStyle {
    /// The settings these letters have their own of, in `TextRunSetting`'s
    /// order.
    var ownSettings: [TextRunSetting] {
        TextRunSetting.allCases.filter { components(of: $0) != nil }
    }

    /// A setting's keyframes as components; nil while the letters take the
    /// block's.
    func components(of setting: TextRunSetting) -> AnimatedValue<ComponentValue>? {
        if let path = setting.number { return self[keyPath: path]?.asComponents }
        if let path = setting.color { return self[keyPath: path] }
        return nil
    }

    /// Changes a setting the letters have their own of, as components;
    /// one they take the block's of is left alone.
    mutating func changeComponents(of setting: TextRunSetting, _ change: (inout AnimatedValue<ComponentValue>) -> Void) {
        if let path = setting.number, var components = self[keyPath: path]?.asComponents {
            change(&components)
            self[keyPath: path] = AnimatedValue(components: components)
        } else if let path = setting.color, self[keyPath: path] != nil {
            change(&self[keyPath: path]!)
        }
    }
}

extension TextContent {
    /// Changes the style of the run starting at code unit `start`, as
    /// kept: its letters stay a run of their own even if the change makes
    /// them match a neighbour's, so a row showing it keeps its place.
    mutating func changeRun(startingAt start: Int, _ change: (inout TextRunStyle) -> Void) {
        guard let index = runs.firstIndex(where: { $0.start == start }) else { return }
        change(&runs[index].style)
    }

    /// A run's letters in quotes, for a header naming it: “Hello”, cut
    /// short past 16 letters, line breaks shown as spaces.
    func quotedLetters(of run: TextRun) -> String {
        let text = string as NSString
        let lower = max(0, min(run.start, text.length)), upper = max(lower, min(run.end, text.length))
        let letters = text.substring(with: NSRange(location: lower, length: upper - lower))
            .map { $0.isNewline ? " " : String($0) }.joined()
        let shown = letters.count > 16 ? String(letters.prefix(15)) + "…" : letters
        return "\u{201C}\(shown)\u{201D}"
    }
}

/// Letters of a Text effect's words styled alike: a range of UTF-16 code
/// units, as `NSString` and the text editor count them.
struct TextRun: Equatable, Sendable {
    var start: Int
    var length: Int
    var style: TextRunStyle

    var end: Int { start + length }
    var range: NSRange { NSRange(location: start, length: length) }
}

/// A run's settings at one moment, as its letters are laid out.
struct TextStyleRun: Hashable, Sendable {
    var start: Int
    var length: Int
    var style: TextStyle

    var end: Int { start + length }
}

extension [TextStyleRun] {
    /// What the letter at code unit `index` sets; nothing past the end.
    func style(at index: Int) -> TextStyle {
        first { $0.start <= index && index < $0.end }?.style ?? .none
    }
}

extension TextContent {
    /// The words' length in UTF-16 code units, which runs count in.
    var length: Int { (string as NSString).length }

    /// The spans in which any of its runs' settings or its font's axes are
    /// between keyframes.
    var animatedRanges: [ClosedRange<CMTime>] {
        runs.flatMap(\.style.animatedRanges) + variations.compactMap(\.value.animatedRange)
    }

    /// Applies an ease to every keyframe its runs and axes have at `time`,
    /// for F9. Returns whether there was one.
    mutating func applyEase(_ preset: KeyframeEase.Preset, at time: CMTime) -> Bool {
        var eased = false
        for index in runs.indices where runs[index].style.applyEase(preset, at: time) { eased = true }
        for index in variations.indices where variations[index].value.keyframe(at: time) != nil {
            variations[index].value.applyEase(preset, at: time)
            eased = true
        }
        return eased
    }

    /// Its runs' settings at source time `time`.
    func runs(at time: CMTime) -> [TextStyleRun] {
        runs.map { TextStyleRun(start: $0.start, length: $0.length, style: $0.style.at(time)) }
    }

    /// The style of each code unit: what its run sets, or nothing.
    var unitStyles: [TextRunStyle] {
        var styles = [TextRunStyle](repeating: .none, count: length)
        for run in runs {
            for unit in max(0, run.start)..<min(length, run.end) where run.start < run.end { styles[unit] = run.style }
        }
        return styles
    }

    /// Runs from one style per code unit: adjacent units styled alike join,
    /// and unstyled ones have none.
    static func runs(from styles: [TextRunStyle]) -> [TextRun] {
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
    func style(at index: Int) -> TextRunStyle {
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
    mutating func changeStyle(in range: NSRange, _ change: (inout TextRunStyle) -> Void) {
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
        styles.replaceSubrange(lower..<upper, with: [TextRunStyle](repeating: typed, count: count))
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
