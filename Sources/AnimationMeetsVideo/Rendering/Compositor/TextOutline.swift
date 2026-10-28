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
        /// Whether a word may break across wrapped lines, with a hyphen.
        var hyphenate = false
        /// Which point of the block sits at its position.
        var anchor = TextAnchor.center

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

        /// Letters styled apart from the block (`TextContent.runs`), as
        /// they are at this moment.
        var runs: [TextStyleRun] = []
        /// Where variable fonts sit along their axes, at this moment.
        var variations: [AxisValue] = []

        struct AxisValue: Hashable, Sendable {
            /// A four-letter tag ("wght").
            var axis: String
            var value: Double
        }

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
            runs = content.runs(at: time)
            variations = content.variations.map { AxisValue(axis: $0.axis, value: $0.value.value(at: time)) }
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
            hyphenate = isOn(.hyphenate)
            anchor = choice(.textAnchor, .center)
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
                kerning: style.kerning ?? 0, position: style.position ?? .normal, strokeWidth: style.strokeWidth,
                leading: max(0, style.leading ?? leading), characterRotation: style.characterRotation ?? characterRotation,
                offsetX: style.offsetX ?? 0, offsetY: style.offsetY ?? 0
            )
        }
    }

    /// Letters drawn alike: their outline, in the frame's pixels, and the
    /// colors and opacity they are filled and stroked with.
    struct Piece {
        var path: CGPath
        /// Nil while neither the block nor the letters' run has a fill, or
        /// a stroke.
        var fill: [Double]?
        var stroke: [Double]?
        /// The run's own stroke width; nil where the block's is used.
        var strokeWidth: Double?
        var opacity = 1.0
    }

    /// A Text Animator below the Text effect, at one moment (see
    /// `TextAnimatorShape`): which units its range selects, and what it
    /// does to each glyph in proportion to how much.
    struct Animator: Equatable, Sendable {
        /// The range, in fractions of all the units, offset included.
        var start = 0.0
        var end = 1.0
        var unit = TextAnimatorUnit.characters
        var shape = TextAnimatorShape.square
        /// Pixels.
        var dx = 0.0
        var dy = 0.0
        /// Fractions: 1 leaves a glyph as it is.
        var scale = 1.0
        var opacity = 1.0
        /// Degrees, clockwise.
        var rotation = 0.0
        /// The colors the glyphs it selects are filled and stroked with;
        /// nil while its Fill or Stroke is off.
        var fill: [Double]?
        var stroke: [Double]?
        /// Thousandths of an em after each glyph it selects.
        var tracking = 0.0

        /// A Text Animator effect at source time `time`; nil while it is off.
        init?(_ effect: Effect, at time: CMTime) {
            guard effect.kind == .textAnimator, effect.enabled else { return nil }
            func values(_ kind: ControlKind) -> [Double] {
                guard let control = effect.control(kind), control.enabled else { return kind.defaultValues }
                return control.values(at: time)
            }
            func number(_ kind: ControlKind) -> Double { values(kind).first ?? 0 }
            func choice<Option: RawRepresentable>(_ kind: ControlKind, _ fallback: Option) -> Option where Option.RawValue == String {
                let picked = effect.control(kind).flatMap { $0.enabled ? $0.choice : nil } ?? kind.defaultChoice
                return picked.flatMap(Option.init(rawValue:)) ?? fallback
            }
            let offset = number(.animatorOffset) / 100
            start = number(.animatorStart) / 100 + offset
            end = number(.animatorEnd) / 100 + offset
            unit = choice(.animatorUnit, .characters)
            shape = choice(.animatorShape, .square)
            let move = values(.animatorPosition)
            dx = move.first ?? 0
            dy = move.count > 1 ? move[1] : 0
            scale = max(0, number(.animatorScale) / 100)
            opacity = (number(.animatorOpacity) / 100).clamped(between: 0, and: 1)
            rotation = number(.animatorRotation)
            if let control = effect.control(.animatorFill), control.enabled {
                fill = control.values(at: time).map { $0.clamped(between: 0, and: 1) }
            }
            if let control = effect.control(.animatorStroke), control.enabled {
                stroke = control.values(at: time).map { $0.clamped(between: 0, and: 1) }
            }
            tracking = number(.animatorTracking)
        }

        init() {}

        /// How much it selects `glyph`, 0 to 1.
        func amount(of glyph: TextLayout.Laid.Glyph, in laid: TextLayout.Laid) -> Double {
            let (index, count) = switch unit {
            case .characters: (glyph.character, laid.characterCount)
            case .charactersExcludingSpaces: (glyph.letter, laid.letterCount)
            case .words: (glyph.word, laid.wordCount)
            case .lines: (glyph.line, laid.lineCount)
            }
            return shape.amount(unit: index, of: count, start: start, end: end)
        }
    }

    var setting: Setting
    /// The middle of the block.
    var center: CGPoint
    /// The Text Animators below the Text effect, in order. They place the
    /// glyphs laid out, so animating them doesn't lay the block out again.
    var animators: [Animator] = []
    /// The outline the text follows, while it is on a path, from
    /// `pathOffset` pixels along it; the anchor and position then don't
    /// place it.
    var followed: TextPath?
    var pathOffset = 0.0
    /// Whether it runs along the path the other way, on its other side.
    var flipped = false
    /// How the block strokes, its width 0 while its stroke is off, which a
    /// run with a stroke of its own is stroked with, at its own width
    /// where it has one.
    var strokeGeometry: ShapeStroke?
    /// The block's stroke color, nil while it is off.
    var strokeColor: [Double]?

    /// The glyphs' outlines, in the frame's pixels.
    var path: CGPath {
        let path = CGMutablePath()
        for piece in pieces(fill: nil, stroke: nil) { path.addPath(piece.path) }
        return path
    }

    /// What one group of letters is drawn with, for gathering them.
    private struct Look: Hashable {
        var style: Int
        /// Thousandths.
        var opacity: Int
        /// The fill's and stroke's components in thousandths, as an
        /// animator recolored them; nil where the style's are.
        var fill: [Int]?
        var stroke: [Int]?
    }

    /// The block's letters and rules placed in the frame, turned and moved
    /// by the animators, and grouped by how they are drawn: each run's
    /// colors over the block's `fill` and `stroke`, where the block has
    /// them, mixed toward an animator's fill, and faded.
    func pieces(fill: [Double]?, stroke: [Double]?) -> [Piece] {
        let laid = TextLayout.shared.laid(setting)
        let anchor = setting.anchor.fraction
        let toFrame = CGAffineTransform(
            translationX: center.x - laid.size.width * anchor.x, y: center.y - laid.size.height * anchor.y
        )
        let amounts = laid.glyphs.map { glyph in animators.map { $0.amount(of: glyph, in: laid) } }
        let shifts = trackingShifts(laid, amounts: amounts)
        let followed = flipped ? self.followed?.reversed() : self.followed

        var looks: [Look] = []
        var paths: [Look: CGMutablePath] = [:]
        var colors: [Look: [Double]] = [:]
        var strokes: [Look: [Double]] = [:]
        func path(for look: Look) -> CGMutablePath {
            if let path = paths[look] { return path }
            let path = CGMutablePath()
            looks.append(look)
            paths[look] = path
            return path
        }
        for (index, glyph) in laid.glyphs.enumerated() {
            // Character Rotation turns the letter alone, as in Illustrator;
            // its rules stay level.
            var turned = CGAffineTransform.identity
            let turn = laid.styles[glyph.style].characterRotation * .pi / 180
            if turn != 0 {
                let pivot = CGPoint(x: glyph.advance / 2, y: -glyph.middle)
                turned = CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
                    .concatenating(CGAffineTransform(rotationAngle: turn))
                    .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y))
            }
            // What moves the letter and its rules alike.
            var place = CGAffineTransform.identity
            var opacity = 1.0
            var fillColor = laid.styles[glyph.style].fill ?? fill
            var strokeColor = laid.styles[glyph.style].stroke ?? stroke
            var refilled = false, restroked = false
            func mix(_ base: [Double]?, toward target: [Double]?, by amount: Double) -> [Double]? {
                guard let base, let target, base.count == 4, target.count == 4 else { return nil }
                return zip(base, target).map { $0 + ($1 - $0) * amount }
            }
            for (animator, amount) in zip(animators, amounts[index]) where amount > 0 {
                // About the middle of its baseline, as After Effects does.
                let pivot = CGPoint(x: glyph.advance / 2, y: 0)
                let scale = 1 + (animator.scale - 1) * amount
                place = place
                    .concatenating(CGAffineTransform(translationX: -pivot.x, y: -pivot.y))
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(rotationAngle: animator.rotation * amount * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: pivot.x + animator.dx * amount, y: pivot.y + animator.dy * amount))
                opacity *= 1 + (animator.opacity - 1) * amount
                if let mixed = mix(fillColor, toward: animator.fill, by: amount) {
                    fillColor = mixed
                    refilled = true
                }
                if let mixed = mix(strokeColor, toward: animator.stroke, by: amount) {
                    strokeColor = mixed
                    restroked = true
                }
            }
            if let followed {
                // The middle of its baseline at its distance along the
                // path, turned to the path's direction there; later lines
                // follow parallel to it.
                let along = pathStart(laid, followed) + glyph.origin.x + shifts[index] + glyph.advance / 2
                let (point, angle) = followed.place(at: along)
                place = place
                    .concatenating(CGAffineTransform(translationX: -glyph.advance / 2, y: glyph.origin.y - laid.firstBaseline))
                    .concatenating(CGAffineTransform(rotationAngle: angle))
                    .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
            } else {
                place = place
                    .concatenating(CGAffineTransform(translationX: glyph.origin.x + shifts[index], y: glyph.origin.y))
                    .concatenating(toFrame)
            }
            func thousandths(_ color: [Double]?) -> [Int]? { color?.map { Int(($0 * 1000).rounded()) } }
            let look = Look(
                style: glyph.style, opacity: Int((opacity * 1000).rounded()),
                fill: refilled ? thousandths(fillColor) : nil, stroke: restroked ? thousandths(strokeColor) : nil
            )
            if refilled, let fillColor { colors[look] = fillColor }
            if restroked, let strokeColor { strokes[look] = strokeColor }
            // Its pieces of the rules move, scale, turn and fade with it.
            let drawn = path(for: look)
            drawn.addPath(glyph.outline, transform: turned.concatenating(place))
            for rule in glyph.rules { drawn.addRect(rule, transform: place) }
        }
        return looks.compactMap { look in
            guard let path = paths[look], !path.isEmpty else { return nil }
            let style = laid.styles[look.style]
            // A run's own color paints its letters whether or not the
            // block's fill or stroke is on.
            return Piece(
                path: path, fill: colors[look] ?? style.fill ?? fill, stroke: strokes[look] ?? style.stroke ?? stroke,
                strokeWidth: style.strokeWidth, opacity: Double(look.opacity) / 1000
            )
        }
    }

    /// How far along `followed` the block's left edge is: the offset, and
    /// for centered or right-aligned text, what centers it on the path or
    /// ends it at the path's end.
    private func pathStart(_ laid: TextLayout.Laid, _ followed: TextPath) -> Double {
        let spare = followed.length - laid.size.width
        return pathOffset + (setting.align == .center ? spare / 2 : setting.align == .right ? spare : 0)
    }

    /// How far along its line each glyph moves for the tracking the
    /// animators add after the glyphs before it, each line then moved back
    /// as its alignment keeps it: half the added width when centered, all
    /// of it at the right.
    private func trackingShifts(_ laid: TextLayout.Laid, amounts: [[Double]]) -> [Double] {
        var shifts = [Double](repeating: 0, count: laid.glyphs.count)
        guard animators.contains(where: { $0.tracking != 0 }) else { return shifts }
        var added: [Int: Double] = [:]
        var last: [Int: Double] = [:]
        for (index, glyph) in laid.glyphs.enumerated() {
            shifts[index] = added[glyph.line, default: 0]
            let size = laid.styles[glyph.style].size
            let extra = zip(animators, amounts[index]).reduce(0) { $0 + $1.1 * $1.0.tracking / 1000 * size }
            added[glyph.line, default: 0] += extra
            last[glyph.line] = extra
        }
        let share: Double = switch setting.align {
        case .center: 0.5
        case .right: 1
        default: 0
        }
        guard share > 0 else { return shifts }
        for (index, glyph) in laid.glyphs.enumerated() {
            // Not counting what follows the line's last glyph.
            let width = added[glyph.line, default: 0] - last[glyph.line, default: 0]
            shifts[index] -= width * share
        }
        return shifts
    }

    /// What it draws, in words, for a render's key: every setting, which
    /// a new one joins without being listed here.
    var keyText: String {
        "h t \(String(describing: setting)) \(String(describing: animators)) \(String(format: "%.5f,%.5f", center.x, center.y))"
            + (followed.map { " p\(String(format: "%.5f", pathOffset)) \($0.closed) \(flipped) \($0.points)" } ?? "")
            + " g\(strokeGeometry?.keyText ?? "-") \(strokeColor ?? [])"
    }
}
