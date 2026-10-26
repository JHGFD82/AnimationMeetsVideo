import CoreGraphics
import CoreMedia
import CoreText
import Foundation
import Testing
@testable import AnimationMeetsVideo

extension DrawingFixture {
    /// Sets the words of every Text effect in the clip's stack.
    mutating func setText(_ string: String, font: String? = nil, ofClip clipID: UUID) {
        project.editClip(clipID, in: timelineID) { clip in
            for e in clip.effects.indices where clip.effects[e].kind == .text {
                clip.effects[e].text?.string = string
                if let font { clip.effects[e].text?.fontName = font }
            }
        }
    }
}

@Suite struct TextTests {
    private let second = CMTime(seconds: 1, preferredTimescale: 600)

    /// A setting of `string` at 100 pixels in Helvetica Neue Bold, centered
    /// and unwrapped, changed by `change`.
    private func setting(_ string: String, _ change: (inout TextOutline.Setting) -> Void = { _ in }) -> TextOutline.Setting {
        var setting = TextOutline.Setting(string: string, fontName: TextContent.defaultFontName, size: 100)
        change(&setting)
        return setting
    }

    /// The setting's glyphs and rules, the block's middle at the origin.
    private func outline(_ setting: TextOutline.Setting) -> CGPath {
        TextOutline(setting: setting, center: .zero).path
    }

    private func bounds(_ setting: TextOutline.Setting) -> CGRect {
        outline(setting).boundingBoxOfPath
    }

    /// The setting's pieces, filled white and stroked black.
    private func pieces(_ setting: TextOutline.Setting) -> [TextOutline.Piece] {
        TextOutline(setting: setting, center: .zero).pieces(fill: [1, 1, 1, 1], stroke: [0, 0, 0, 1])
    }

    // MARK: Styled runs

    @Test func editingKeepsRunsOnTheirLetters() {
        var content = TextContent(string: "Hello world")
        content.changeStyle(in: NSRange(location: 6, length: 5)) { $0.size = AnimatedValue(200) }
        #expect(content.runs == [TextRun(start: 6, length: 5, style: TextRunStyle(fixed: TextStyle(size: 200)))])
        // Typing before the run moves it along; typing inside it widens it.
        content.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Oh, ")
        #expect(content.runs.map(\.range) == [NSRange(location: 10, length: 5)])
        content.replaceCharacters(in: NSRange(location: 12, length: 0), with: "!!")
        #expect(content.runs.map(\.range) == [NSRange(location: 10, length: 7)])
        // Deleting part of it shrinks it; an edit the editor made itself
        // keeps what is unchanged at either end.
        content.replaceCharacters(in: NSRange(location: 10, length: 3), with: "")
        #expect(content.runs.map(\.range) == [NSRange(location: 10, length: 4)])
        content.replaceString(with: "Oh, Hello, there world")
        #expect(content.string == "Oh, Hello, there world")
        // "Oh, Hello !rld": the unchanged "rld" keeps its style.
        #expect(content.runs.map(\.range) == [NSRange(location: 19, length: 3)])
        // Styling letters back to nothing removes the run.
        content.changeStyle(in: NSRange(location: 0, length: content.length)) { $0 = .none }
        #expect(content.runs.isEmpty)
    }

    @Test func adjacentLettersStyledAlikeAreOneRun() {
        var content = TextContent(string: "abcdef")
        content.changeStyle(in: NSRange(location: 0, length: 2)) { $0.underline = true }
        content.changeStyle(in: NSRange(location: 2, length: 2)) { $0.underline = true }
        content.changeStyle(in: NSRange(location: 3, length: 3)) { $0.tracking = AnimatedValue(50) }
        #expect(content.runs == [
            TextRun(start: 0, length: 3, style: TextRunStyle(fixed: TextStyle(underline: true))),
            TextRun(start: 3, length: 1, style: TextRunStyle(fixed: TextStyle(tracking: 50, underline: true))),
            TextRun(start: 4, length: 2, style: TextRunStyle(fixed: TextStyle(tracking: 50))),
        ])
    }

    @Test func aRunSetsItsLettersApartFromTheBlock() {
        let plain = setting("HHHH")
        var bigger = plain
        bigger.runs = [TextStyleRun(start: 2, length: 2, style: TextStyle(size: 200))]
        // The two big letters are twice as wide and the block as tall as them.
        let small = bounds(plain), mixed = bounds(bigger)
        #expect(abs(mixed.width - small.width * 1.5) < 4)
        #expect(mixed.height > small.height * 1.8)

        var shifted = plain
        shifted.runs = [TextStyleRun(start: 0, length: 1, style: TextStyle(baselineShift: 40))]
        #expect(abs(bounds(shifted).minY - (small.minY - 40)) < 0.5)

        var wide = plain
        wide.runs = [TextStyleRun(start: 0, length: 4, style: TextStyle(horizontalScale: 200))]
        #expect(abs(bounds(wide).width - small.width * 2) < 4)

        var capped = setting("hello")
        capped.runs = [TextStyleRun(start: 0, length: 5, style: TextStyle(textCase: .allCaps))]
        #expect(bounds(capped) == bounds(setting("HELLO")))
    }

    @Test func aRunsColorsPaintItsLetters() {
        var styled = setting("ab")
        styled.runs = [TextStyleRun(start: 1, length: 1, style: TextStyle(fill: [1, 0, 0, 1], stroke: [0, 0, 1, 1]))]
        let drawn = pieces(styled)
        #expect(drawn.count == 2)
        #expect(drawn.map(\.fill) == [[1, 1, 1, 1], [1, 0, 0, 1]])
        #expect(drawn.map(\.stroke) == [[0, 0, 0, 1], [0, 0, 1, 1]])
        // Without a block fill or stroke, a run's own colors still paint
        // its letters, and the rest are left unpainted.
        let bare = TextOutline(setting: styled, center: .zero).pieces(fill: nil, stroke: nil)
        #expect(bare.map(\.fill) == [nil, [1, 0, 0, 1]])
        #expect(bare.map(\.stroke) == [nil, [0, 0, 1, 1]])
    }

    @Test func aRunsStrokeDrawsWhenTheBlockHasNone() throws {
        var effect = Effect(kind: .text)
        effect.text = TextContent(string: "ab")
        // The block's stroke is off and has no width.
        effect.changeControl(.stroke) { $0.enabled = false }
        let plain = try #require(ShapeStep(effect, at: .zero, center: .zero))
        #expect(plain.paints.count == 1)
        effect.text?.changeStyle(in: NSRange(location: 1, length: 1)) { style in
            style.stroke = AnimatedValue(ComponentValue(values: [1, 0, 0, 1]))
            style.strokeWidth = AnimatedValue(4)
        }
        let stroked = try #require(ShapeStep(effect, at: .zero, center: .zero))
        // Both letters' fill, and the run's stroke.
        #expect(stroked.paints.count == 3)
        #expect(stroked.paints.last?.color == [1, 0, 0, 1])
        // A run's width with no color of its own takes the block's color,
        // which is off, so draws nothing.
        var widthOnly = effect
        widthOnly.text?.changeStyle(in: NSRange(location: 1, length: 1)) { $0.stroke = nil }
        #expect(try #require(ShapeStep(widthOnly, at: .zero, center: .zero)).paints.count == 2)
    }

    @Test func aRunsKeyframesReplaceTheBlocksForItsLetters() throws {
        let second = CMTime(seconds: 1, preferredTimescale: 600)
        var effect = Effect(kind: .text)
        effect.text = TextContent(string: "ab")
        // The block grows from 100 to 200; the run's own size from 50 to 60.
        effect.changeControl(.fontSize) { size in
            size.number.setAnimated(true, at: .zero)
            size.setComponent(0, to: 100, at: .zero)
            size.setComponent(0, to: 200, at: second)
        }
        effect.text?.changeStyle(in: NSRange(location: 1, length: 1)) { style in
            var size = AnimatedValue(50.0)
            size.setAnimated(true, at: .zero)
            size.set(60, at: second)
            style.size = size
        }
        let start = try #require(TextOutline.Setting(effect, at: .zero))
        let end = try #require(TextOutline.Setting(effect, at: second))
        #expect(start.size == 100 && end.size == 200)
        #expect(start.runs.style(at: 1).size == 50)
        #expect(end.runs.style(at: 1).size == 60)
        // The first letter, with no size of its own, follows the block's.
        #expect(start.runs.style(at: 0).size == nil)

        // Its keyframes are animation the render cache redraws, and F9
        // eases them.
        #expect(effect.animatedRanges.contains(.zero...second))
        var clip = TimelineClip(source: .graphic, startOffset: .zero, trimStart: .zero, trimEnd: CMTime(seconds: 2, preferredTimescale: 600))
        clip.effects = [effect]
        let easedAny = clip.easeKeyframes(atTimelineTime: second, .easeIn)
        #expect(easedAny)
        let eased = try #require(clip.effects[0].text?.runs.first?.style.size?.keyframes.last)
        #expect(eased != effect.text?.runs.first?.style.size?.keyframes.last)
    }

    @Test func aRunCanUnderlineSomeLetters() {
        var styled = setting("HHHH")
        styled.runs = [TextStyleRun(start: 0, length: 2, style: TextStyle(underline: true))]
        let underlined = pieces(styled).first { _ in true }
        let plain = bounds(setting("HHHH"))
        #expect(bounds(styled).maxY > plain.maxY + 2)
        // The rule spans only the first two letters.
        #expect((underlined?.path.boundingBoxOfPath.width ?? 0) < plain.width * 0.6)
    }

    @Test func kerningByHandSpacesOnePair() {
        let plain = setting("AVAV")
        var kerned = plain
        // 200 thousandths at 100 pixels: 20 pixels between the first pair.
        kerned.runs = [TextStyleRun(start: 0, length: 1, style: TextStyle(kerning: 200))]
        #expect(abs(bounds(kerned).width - bounds(plain).width - 20) < 0.5, "\(bounds(kerned).width - bounds(plain).width)")
        // The font's own pair kerning stays.
        var unkerned = plain
        unkerned.kerning = .none
        #expect(bounds(plain).width < bounds(unkerned).width)
    }

    @Test func aCursorKernsThePairAroundIt() {
        let content = TextContent(string: "AV\nW")
        #expect(content.kerningPair(at: 1) == NSRange(location: 0, length: 1))
        #expect(content.kerningPair(at: 0) == nil)
        #expect(content.kerningPair(at: 2) == nil)
        #expect(content.kerningPair(at: 4) == nil)
        // A letter of two code units is one letter of the pair.
        #expect(TextContent(string: "😀A").kerningPair(at: 2) == NSRange(location: 0, length: 2))
    }

    @Test func superscriptsAndSubscriptsAreMadeWhereTheFontHasNone() {
        // Helvetica Neue has no 'sups': a third of the size up, at 58.3%.
        #expect(!FontCatalog.supports(TextContent.defaultFontName, feature: "sups"))
        let plain = bounds(setting("H"))
        var raised = setting("H")
        raised.runs = [TextStyleRun(start: 0, length: 1, style: TextStyle(position: .superscript))]
        var lowered = raised
        lowered.runs[0].style.position = .subscript
        let up = bounds(raised), down = bounds(lowered)
        #expect(abs(up.height - plain.height * TextPosition.syntheticSize) < 1)
        #expect(down.height == up.height)
        // Beside an ordinary H, its baseline is 33.3 pixels up or down.
        func baselines(_ position: TextPosition) -> (plain: CGFloat, moved: CGFloat) {
            var pair = setting("HH")
            pair.runs = [TextStyleRun(start: 1, length: 1, style: TextStyle(position: position))]
            let drawn = pieces(pair).map(\.path.boundingBoxOfPath.maxY)
            return (drawn[0], drawn[1])
        }
        let superscript = baselines(.superscript), subscripted = baselines(.subscript)
        #expect(abs(superscript.moved - (superscript.plain - 33.3)) < 0.5)
        #expect(abs(subscripted.moved - (subscripted.plain + 33.3)) < 0.5)
    }

    @Test func aFontsOwnSuperscriptsAreUsedWhereItHasThem() {
        let style = TextLayout.LetterStyle(
            fontName: TextContent.defaultFontName, size: 100, tracking: 0, baselineShift: 0, horizontalScale: 100, verticalScale: 100,
            textCase: .normal, underline: false, strikethrough: false, position: .superscript
        )
        #expect(style.resolved().feature == nil)
        #expect(style.resolved().size < 100)
        // Not every Mac has a font with 'sups'; SF Pro does, where installed.
        guard let font = ["SFProText-Regular", "SFPro-Regular"].first(where: { FontCatalog.supports($0, feature: "sups") }) else { return }
        var own = style
        own.fontName = font
        #expect(own.resolved().feature == "sups")
        #expect(own.resolved().size == 100)
        #expect(own.resolved().baselineShift == 0)
    }

    @Test func hyphenationBreaksAWordThatWouldPartlyFit() {
        let words = "go internationalization"
        // The long word fits whole on its own line, but not after "go".
        let wrap = (bounds(setting("internationalization")).width + 30).rounded()
        let plain = setting(words) { $0.wrapWidth = wrap; $0.align = .left }
        var hyphenated = plain
        hyphenated.hyphenate = true
        let laidPlain = TextLayout.layOut(plain), laidHyphenated = TextLayout.layOut(hyphenated)
        #expect(laidPlain.lineCount == 2)
        #expect(laidHyphenated.lineCount == 2)
        // The first line takes part of the word and a hyphen, so it holds
        // more glyphs than "go".
        let firstLine = { (laid: TextLayout.Laid) in laid.glyphs.filter { $0.line == 0 }.count }
        #expect(firstLine(laidPlain) == 2)
        #expect(firstLine(laidHyphenated) > 4)
        #expect(bounds(hyphenated).width <= wrap)
        // Every letter keeps its place in the words, for animators.
        #expect(laidHyphenated.glyphs.filter { $0.line == 1 }.allSatisfy { $0.word == 1 })
    }

    @Test func hyphenationBreaksAWordTooLongForALine() {
        let word = setting("internationalization") { $0.wrapWidth = 500; $0.align = .left; $0.hyphenate = true }
        let laid = TextLayout.layOut(word)
        #expect(laid.lineCount >= 2)
        #expect(bounds(word).width <= 500)
    }

    @Test func lettersAreNumberedAcrossParagraphs() {
        let laid = TextLayout.layOut(setting("ab cd\nef"))
        #expect(laid.glyphs.map(\.character) == [0, 1, 3, 4, 5, 6])
        #expect(laid.glyphs.map(\.word) == [0, 0, 1, 1, 2, 2])
        #expect(laid.glyphs.map(\.line) == [0, 0, 0, 0, 1, 1])
        #expect(laid.characterCount == 7 && laid.wordCount == 3 && laid.lineCount == 2)
    }

    @Test func opticalKerningClosesOpenPairsAndLeavesStraightOnes() {
        func width(_ string: String, _ kerning: TextKerning) -> CGFloat { bounds(setting(string) { $0.kerning = kerning }).width }
        // Diagonals and overhangs close up, as the font's pairs do.
        #expect(width("AV", .optical) < width("AV", .none) - 5)
        #expect(width("To", .optical) < width("To", .none) - 5)
        // The reference pairs keep the font's own spacing.
        #expect(abs(width("HH", .optical) - width("HH", .none)) < 1)
        #expect(abs(width("nn", .optical) - width("nn", .none)) < 1)
        // Spaces are left alone.
        #expect(abs(width("A V", .optical) - width("A V", .none)) < 1)
        // About as much as the font's designer closed them.
        for pair in ["AV", "To", "Ty", "LT"] {
            let designed = width(pair, .none) - width(pair, .metrics), optical = width(pair, .none) - width(pair, .optical)
            #expect(optical > designed * 0.5 && optical < designed * 2, "\(pair): designed \(designed), optical \(optical)")
        }
    }

    @Test func aGlyphsProfileFollowsItsShape() {
        let font = CTFontCreateWithName(TextContent.defaultFontName as CFString, 100, nil)
        func glyph(_ letter: String) -> CGGlyph {
            var characters = Array(letter.utf16)
            var glyph = CGGlyph(0)
            CTFontGetGlyphsForCharacters(font, &characters, &glyph, 1)
            return glyph
        }
        // An A is wider at its foot than its peak; an H's sides are straight.
        let a = OpticalKerning.profile(glyph("A"), font)
        let inked = a.left.indices.filter { a.left[$0] != nil }
        let top = try? #require(inked.first), foot = try? #require(inked.last)
        if let top, let foot, let topLeft = a.left[top], let footLeft = a.left[foot] { #expect(topLeft > footLeft + 0.1) }
        let h = OpticalKerning.profile(glyph("H"), font)
        let lefts = h.left.compactMap { $0 }
        #expect((lefts.max() ?? 0) - (lefts.min() ?? 1) < 0.03)
    }

    @Test func smallCapsAreMadeWhereTheFontHasNone() {
        // Helvetica Neue has no 'smcp': lowercase letters become capitals
        // at 70% of the size, beside full-size capitals.
        #expect(!FontCatalog.supports(TextContent.defaultFontName, feature: "smcp"))
        let drawn = pieces(setting("Hello") { $0.textCase = .smallCaps })
        #expect(drawn.count == 2)
        let capital = drawn[0].path.boundingBoxOfPath, small = drawn[1].path.boundingBoxOfPath
        #expect(small.height < capital.height * 0.8)
        // Their shapes are capitals': "ELLO" at 70%.
        let capitals = bounds(setting("ELLO") { $0.size = 70 })
        #expect(abs(small.width - capitals.width) < 1)
        #expect(abs(small.height - capitals.height) < 0.5)
        // All Small Caps makes the capital small too.
        #expect(pieces(setting("Hello") { $0.textCase = .allSmallCaps }).count == 1)
        #expect(abs(bounds(setting("Hello") { $0.textCase = .allSmallCaps }).height - small.height) < 0.5)
    }

    @Test func aFontsOwnSmallCapsAreUsedWhereItHasThem() {
        // Didot, which every Mac has, draws its own.
        guard FontCatalog.supports("Didot", feature: "smcp") else { return }
        let own = pieces(setting("Hello") { $0.textCase = .smallCaps; $0.fontName = "Didot" })
        #expect(own.count == 1)
        #expect(bounds(setting("Hello") { $0.textCase = .smallCaps; $0.fontName = "Didot" })
            != bounds(setting("Hello") { $0.fontName = "Didot" }))
    }

    @Test func theAnchorPutsAPointOfTheBlockAtThePosition() {
        func anchored(_ anchor: TextAnchor) -> CGRect {
            bounds(setting("Hi\nHi") { $0.wrapWidth = 600; $0.align = .left; $0.anchor = anchor })
        }
        let block = TextLayout.layOut(setting("Hi\nHi") { $0.wrapWidth = 600 }).size
        let topLeft = anchored(.topLeft), bottomRight = anchored(.bottomRight), middle = anchored(.center)
        // The block's top left at the origin: the letters start just right
        // of it and below it.
        #expect(topLeft.minX >= 0 && topLeft.minX < 15)
        #expect(topLeft.minY > 0)
        // Its bottom right at the origin: the block is 600 wide.
        #expect(abs(bottomRight.minX - (topLeft.minX - 600)) < 0.5)
        #expect(abs(bottomRight.minY - (topLeft.minY - block.height)) < 0.5)
        #expect(abs(middle.minX - (topLeft.minX - 300)) < 0.5)
        let top = anchored(.top), left = anchored(.left)
        #expect(abs(top.minY - topLeft.minY) < 0.5 && abs(top.minX - middle.minX) < 0.5)
        #expect(abs(left.minX - topLeft.minX) < 0.5 && abs(left.minY - middle.minY) < 0.5)
    }

    // MARK: Animators

    @Test func eachRangeShapeSelectsAlongTheRange() {
        // Ten units, the range over the middle half.
        func amounts(_ shape: TextAnimatorShape) -> [Double] {
            (0..<10).map { shape.amount(unit: $0, of: 10, start: 0.25, end: 0.75) }
        }
        let square = amounts(.square)
        #expect(square[0] == 0 && square[4] == 1 && square[9] == 0)
        // A unit the range's edge crosses is partly selected.
        #expect(abs(square[2] - 0.5) < 1e-9)
        let up = amounts(.rampUp), down = amounts(.rampDown)
        #expect(up[0] == 0 && up[9] == 1 && up[3] < up[6])
        #expect(down[0] == 1 && down[9] == 0 && down[3] > down[6])
        for shape in [TextAnimatorShape.triangle, .round, .smooth] {
            let values = amounts(shape)
            #expect(values[0] == 0 && values[9] == 0)
            #expect(values[4] > values[3] && values[5] > values[6])
        }
    }

    @Test func anAnimatorMovesFadesAndRecolorsWhatItSelects() {
        var animator = TextOutline.Animator()
        animator.end = 0.5
        animator.dy = -50
        animator.opacity = 0.5
        animator.fill = [1, 0, 0, 1]
        let block = setting("HHHH")
        let still = TextOutline(setting: block, center: .zero).pieces(fill: [1, 1, 1, 1], stroke: nil)
        let moved = TextOutline(setting: block, center: .zero, animators: [animator]).pieces(fill: [1, 1, 1, 1], stroke: nil)
        #expect(still.count == 1)
        #expect(moved.count == 2)
        let raised = moved.first { $0.opacity == 0.5 }, rest = moved.first { $0.opacity == 1 }
        #expect(raised?.fill == [1, 0, 0, 1])
        #expect(rest?.fill == [1, 1, 1, 1])
        // The first two letters rise 50 pixels; the others stay.
        let base = still[0].path.boundingBoxOfPath
        #expect(abs((raised?.path.boundingBoxOfPath.minY ?? 0) - (base.minY - 50)) < 0.5)
        #expect(abs((rest?.path.boundingBoxOfPath.minY ?? 0) - base.minY) < 0.5)
        #expect(abs((raised?.path.boundingBoxOfPath.minX ?? 0) - base.minX) < 0.5)
    }

    @Test func rulesMoveWithTheLettersTheyAreUnder() {
        let block = setting("HHHH") { $0.underline = true }
        var raise = TextOutline.Animator()
        raise.end = 0.5
        raise.dy = -50
        raise.opacity = 0.5
        let still = TextOutline(setting: block, center: .zero).pieces(fill: [1, 1, 1, 1], stroke: nil)
        let moved = TextOutline(setting: block, center: .zero, animators: [raise]).pieces(fill: [1, 1, 1, 1], stroke: nil)
        let base = still[0].path.boundingBoxOfPath
        let raised = moved.first { $0.opacity == 0.5 }?.path.boundingBoxOfPath ?? .zero
        let rest = moved.first { $0.opacity == 1 }?.path.boundingBoxOfPath ?? .zero
        // The underline under the first two letters rose with them, faded
        // with them, and the rest stayed.
        #expect(abs(raised.maxY - (base.maxY - 50)) < 0.5)
        #expect(abs(rest.maxY - base.maxY) < 0.5)
        // Together they span the whole word, with no gap where they meet.
        #expect(abs(raised.minX - base.minX) < 0.5 && abs(rest.maxX - base.maxX) < 0.5)
        #expect(abs(raised.maxX - rest.minX) < 1)
    }

    @Test func rulesRunUnderSpacesAndStayLevelAsLettersTurn() {
        let spaced = bounds(setting("i i") { $0.underline = true })
        let letters = bounds(setting("i i"))
        // The underline spans the space between the two letters.
        #expect(spaced.width >= letters.width - 1)
        let text = outline(setting("i i") { $0.underline = true })
        #expect(text.contains(CGPoint(x: letters.midX, y: spaced.maxY - 1)))
        // Character Rotation turns the letters, not their underline.
        let turned = bounds(setting("HHHH") { $0.underline = true; $0.characterRotation = 90 })
        let plain = bounds(setting("HHHH") { $0.underline = true })
        #expect(turned.width >= plain.width - 1)
    }

    @Test func anAnimatorRecolorsStrokesAndFills() {
        var recolor = TextOutline.Animator()
        recolor.fill = [1, 0, 0, 1]
        recolor.stroke = [0, 0, 1, 1]
        let drawn = TextOutline(setting: setting("ab"), center: .zero, animators: [recolor]).pieces(fill: [1, 1, 1, 1], stroke: [0, 0, 0, 1])
        #expect(drawn.count == 1)
        #expect(drawn[0].fill == [1, 0, 0, 1])
        #expect(drawn[0].stroke == [0, 0, 1, 1])
        // Halfway selected, halfway there.
        var half = recolor
        half.end = 0.75
        half.shape = .rampDown
        let mixed = TextOutline(setting: setting("ab"), center: .zero, animators: [half]).pieces(fill: [1, 1, 1, 1], stroke: [0, 0, 0, 1])
        #expect(mixed.contains { ($0.stroke?[2] ?? 0) > 0 && ($0.stroke?[2] ?? 1) < 1 })
        // A new animator's Stroke starts off.
        #expect(Effect(kind: .textAnimator).control(.animatorStroke)?.enabled == false)
    }

    @Test func anAnimatorScalesAndTurnsEachGlyphAboutItsBaseline() {
        var grow = TextOutline.Animator()
        grow.scale = 2
        let block = setting("I")
        let plain = bounds(block)
        let grown = TextOutline(setting: block, center: .zero, animators: [grow]).path.boundingBoxOfPath
        #expect(abs(grown.height - plain.height * 2) < 1)
        // The baseline stays where it was.
        #expect(abs(grown.maxY - plain.maxY) < 0.5)
        var turn = TextOutline.Animator()
        turn.rotation = 90
        let turned = TextOutline(setting: block, center: .zero, animators: [turn]).path.boundingBoxOfPath
        #expect(turned.width > turned.height * 2)
    }

    @Test func anAnimatorsTrackingSpreadsTheLettersAndKeepsThemCentered() {
        var spread = TextOutline.Animator()
        spread.tracking = 200
        let block = setting("HHHHH")
        let plain = bounds(block)
        let wide = TextOutline(setting: block, center: .zero, animators: [spread]).path.boundingBoxOfPath
        // 20 pixels after each of the first four letters.
        #expect(abs(wide.width - plain.width - 80) < 0.5)
        #expect(abs(wide.midX - plain.midX) < 0.5)
    }

    @Test func aRangeCanCountWordsAndLines() {
        let laid = TextLayout.layOut(setting("ab cd\nef"))
        var words = TextOutline.Animator()
        words.unit = .words
        words.end = 1.0 / 3
        #expect(laid.glyphs.map { words.amount(of: $0, in: laid) } == [1, 1, 0, 0, 0, 0])
        var lines = words
        lines.unit = .lines
        lines.start = 0.5
        lines.end = 1
        #expect(laid.glyphs.map { lines.amount(of: $0, in: laid) } == [0, 0, 0, 0, 1, 1])
    }

    @Test func aTextAnimatorBelowATextEffectDrawsAndSaves() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let text = try fixture.addShape(.text)
        fixture.setText("I", ofClip: text.clipID)
        fixture.setControl(.fontSize, [48], ofClip: text.clipID)
        let before = try await fixture.build().segments.filter(\.needsRender).map(\.key)
        let added = fixture.project.addEffect(.textAnimator, toClip: text.clipID, in: fixture.timelineID)
        #expect(added != nil)
        // It changes nothing until told to: the I's stem still covers the middle.
        let untouched = try await grayLevel(of: fixture.build(), at: second)
        #expect(untouched > 220)
        fixture.setControl(.animatorPosition, [40, 0], ofClip: text.clipID)
        let composed = try await fixture.build()
        let after = composed.segments.filter(\.needsRender).map(\.key)
        #expect(Set(after).isDisjoint(with: Set(before)))
        // The I's stem moved off the middle.
        let middle = try await grayLevel(of: composed, at: second)
        #expect(middle < 10)

        let package = fixture.directory.appending(path: "Animator.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(fixture.project, to: package)
        let loaded = try await ProjectStore.load(from: package)
        let saved = try #require(fixture.project.clipAndLayer(text.clipID, in: fixture.timelineID)?.clip)
        let read = try #require(loaded.project.clipAndLayer(text.clipID, in: loaded.project.rootTimelineID)?.clip)
        #expect(read.effects == saved.effects)
        #expect(read.effects.last?.control(.animatorFill)?.enabled == false)
    }

    @Test func aTextAnimatorWithNoTextAboveSaysSo() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let layer = project.addShapeLayer(.rectangle, to: t)
        let shape = try #require(layer)
        _ = project.addEffect(.textAnimator, toClip: shape.clipID, in: t)
        let (clip, onLayer) = try #require(project.clipAndLayer(shape.clipID, in: t))
        let timeline = try #require(project.timeline(id: t))
        #expect(project.note(forEffectAt: 1, in: clip, on: onLayer, of: timeline)?.dims == true)
        #expect(!EffectKind.textAnimator.drawsShape)
    }

    // MARK: Text on a path

    @Test func aPathIsMeasuredAndWalked() throws {
        let square = try #require(TextPath(flattening: CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)))
        #expect(square.closed)
        #expect(abs(square.length - 400) < 1e-9)
        let corner = square.place(at: 150)
        #expect(abs(corner.point.x - 100) < 1e-9 && abs(corner.point.y - 50) < 1e-9)
        // Round again, and backwards.
        #expect(abs(square.place(at: 550).point.y - 50) < 1e-9)
        #expect(abs(square.place(at: -50).point.y - 50) < 1e-9)
        let circle = try #require(TextPath(flattening: CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200), transform: nil)))
        #expect(abs(circle.length - 200 * .pi) < 2)
        // An open line runs on past its end.
        let line = TextPath(points: [.zero, CGPoint(x: 100, y: 0)], closed: false)
        #expect(line.place(at: 150).point == CGPoint(x: 150, y: 0))
    }

    @Test func aClosedOutlineRunsClockwiseFromItsTop() throws {
        // Core Graphics draws an ellipse from its right, counter-clockwise
        // on screen; text runs from its top, clockwise, as in Illustrator.
        let circle = try #require(TextPath(flattening: CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200), transform: nil)))
        let start = circle.place(at: 0), soon = circle.place(at: 20)
        #expect(abs(start.point.x - 100) < 1 && abs(start.point.y) < 1)
        // Heading right at the top, so going clockwise.
        #expect(soon.point.x > start.point.x && abs(start.angle) < 0.1)
        // A quarter of the way round, at the right.
        let quarter = circle.place(at: circle.length / 4)
        #expect(abs(quarter.point.x - 200) < 1 && abs(quarter.point.y - 100) < 1)
        // A polygon drawn the other way is turned round too.
        let backwards = CGMutablePath()
        backwards.addLines(between: [CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100), CGPoint(x: 50, y: 0)])
        backwards.closeSubpath()
        let triangle = try #require(TextPath(flattening: backwards))
        #expect(triangle.points.first == CGPoint(x: 50, y: 0))
        #expect(triangle.points[1] == CGPoint(x: 100, y: 100))
        // A rectangle already starts at its top left, clockwise.
        let square = try #require(TextPath(flattening: CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)))
        #expect(square.points.prefix(2) == [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
    }

    @Test func flippingRunsTheOtherWayOnTheOtherSide() throws {
        let circle = try #require(TextPath(flattening: CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 600, height: 600), transform: nil)))
        let flipped = circle.reversed()
        #expect(flipped.points.first == circle.points.first)
        #expect(abs(flipped.length - circle.length) < 1e-6)
        // From the top it heads left now.
        #expect(flipped.place(at: 20).point.x < flipped.place(at: 0).point.x)
        // Outside, the letters reach beyond the circle; flipped, inside it.
        var outside = TextOutline(setting: setting("Around") { $0.align = .left }, center: .zero)
        outside.followed = circle
        var inside = outside
        inside.flipped = true
        let out = outside.path.boundingBoxOfPath, within = inside.path.boundingBoxOfPath
        // Outside, a capital's height above the circle's top; flipped,
        // hanging inside it, only round letters' overshoot above it.
        #expect(out.minY < -50)
        #expect(within.minY > -5 && within.maxY > 50)
        #expect(outside.keyText != inside.keyText)
    }

    @Test func textFollowsAnOutlineWhereMovesHavePutIt() throws {
        var text = Effect(kind: .text)
        text.text = TextContent(string: "Along")
        text.changeControl(.textOnPath) { $0.choice = OnOff.on.rawValue }
        let line = TextPath(points: [.zero, CGPoint(x: 1000, y: 0)], closed: false)
        let step = try #require(ShapeStep(text, at: .zero, center: .zero, followed: line))
        // The outline was moved 30 pixels right after it was drawn; the
        // text, drawn now, follows it there.
        let outline = CGMutablePath()
        outline.addLines(between: [.zero, CGPoint(x: 1000, y: 0)])
        let moved = ShapeRendering.Edge(area: outline, transform: CGAffineTransform(translationX: 30, y: 0))
        let following = ShapeRendering.following(step, outline: moved, current: .identity)
        guard case .text(let followed) = following.outline else { Issue.record("Not text"); return }
        #expect(followed.followed?.points.first == CGPoint(x: 30, y: 0))
        // Shapes other than text, and text not on a path, are left as they are.
        var plain = text
        plain.changeControl(.textOnPath) { $0.choice = OnOff.off.rawValue }
        let unmoved = try #require(ShapeStep(plain, at: .zero, center: .zero, followed: line))
        #expect(ShapeRendering.following(unmoved, outline: moved, current: .identity) == unmoved)
    }

    @Test func textFollowsAPathFromItsOffset() {
        var onLine = TextOutline(setting: setting("HHH") { $0.align = .left }, center: .zero)
        onLine.followed = TextPath(points: [CGPoint(x: 0, y: 500), CGPoint(x: 2000, y: 500)], closed: false)
        onLine.pathOffset = 100
        let along = onLine.path.boundingBoxOfPath
        // The H's sit on the line, starting 100 pixels along it.
        #expect(abs(along.maxY - 500) < 0.5)
        #expect(along.minX > 100 && along.minX < 115)
        // Going down a vertical line, the letters turn with it.
        var down = onLine
        down.followed = TextPath(points: [CGPoint(x: 500, y: 0), CGPoint(x: 500, y: 2000)], closed: false)
        let turned = down.path.boundingBoxOfPath
        #expect(turned.height > turned.width * 2)
        #expect(abs(turned.minX - 500) < 0.5 || abs(turned.maxX - 500) < 0.5)
        // Centered text sits in the middle of the path.
        var centered = TextOutline(setting: setting("HHH"), center: .zero)
        centered.followed = TextPath(points: [CGPoint(x: 0, y: 500), CGPoint(x: 2000, y: 500)], closed: false)
        #expect(abs(centered.path.boundingBoxOfPath.midX - 1000) < 6)
    }

    @Test func textOnPathFollowsTheShapeAboveIt() throws {
        var rectangle = Effect(kind: .rectangle)
        rectangle.changeControl(.shapeSize) { $0.number = AnimatedValue(ComponentValue(values: [800, 400])) }
        var text = Effect(kind: .text)
        text.text = TextContent(string: "Around")
        func step(onPath: Bool) -> TextOutline? {
            var effect = text
            effect.changeControl(.textOnPath) { $0.choice = (onPath ? OnOff.on : .off).rawValue }
            let steps = StackFolding.steps(effects: [rectangle, effect], anchorPoint: AnimatedValue(.zero), at: .zero, center: CGPoint(x: 960, y: 540))
            for case .shape(let shape) in steps {
                if case .text(let outline) = shape.outline { return outline }
            }
            return nil
        }
        let off = try #require(step(onPath: false)), on = try #require(step(onPath: true))
        #expect(off.followed == nil)
        let followed = try #require(on.followed)
        #expect(abs(followed.length - 2400) < 1e-6)
        // The path runs clockwise from the rectangle's top left (560, 340),
        // so centered on its length the words turn its bottom right
        // corner (1360, 740), standing outside both edges.
        let bounds = on.path.boundingBoxOfPath
        #expect(bounds.minX > 1100 && bounds.minY > 500)
        #expect(bounds.maxX > 1360 && bounds.maxY > 740)
    }

    // MARK: Missing fonts

    @Test func exportStopsOnAMissingFontButTheViewerDraws() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let text = try fixture.addShape(.text)
        fixture.setText("Hello", font: "NoSuchFont-Bold", ofClip: text.clipID)

        #expect(fixture.project.missingFonts(in: fixture.timelineID) == ["NoSuchFont-Bold"])
        await #expect(throws: CompositionError.self) { try await fixture.build() }
        do {
            _ = try await fixture.build()
        } catch CompositionError.missingFont(let name) {
            #expect(name == "NoSuchFont-Bold")
        }
        let preview = try await fixture.build(forPreview: true)
        #expect(preview.hasPictures)

        // Off, it draws nothing, so its font doesn't matter.
        fixture.project.editClip(text.clipID, in: fixture.timelineID) { $0.effects[0].enabled = false }
        #expect(fixture.project.missingFonts(in: fixture.timelineID).isEmpty)
    }

    @Test func aMissingFontIsFoundInRunsAndNestedTimelines() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let nested = project.addTimeline(name: "Titles", frameSize: CGSize(width: 128, height: 72), frameRate: 24, colorSpace: .rec709)
        let layer = project.addShapeLayer(.text, to: nested)
        let text = try #require(layer)
        project.editClip(text.clipID, in: nested) { clip in
            clip.effects[0].text?.string = "Two fonts"
            clip.effects[0].text?.changeStyle(in: NSRange(location: 0, length: 3)) { $0.fontName = "AlsoMissing-Regular" }
        }
        let embedded = project.embedTimeline(nested, intoTimeline: main)
        #expect(embedded != nil)
        #expect(project.missingFonts(in: main) == ["AlsoMissing-Regular"])
        project.editClip(text.clipID, in: nested) { $0.effects[0].text?.fontName = "NoSuchFont-Bold" }
        #expect(project.missingFonts(in: main) == ["NoSuchFont-Bold", "AlsoMissing-Regular"])
    }

    // MARK: Variable fonts

    @Test func aVariableFontsAxesAreListed() throws {
        // Skia, which every Mac has, varies in weight and width.
        let axes = FontCatalog.axes(of: "Skia-Regular")
        let weight = try #require(axes.first { $0.tag == "wght" })
        #expect(weight.minimum < weight.defaultValue && weight.defaultValue < weight.maximum)
        #expect(axes.contains { $0.tag == "wdth" })
        #expect(FontCatalog.axes(of: TextContent.defaultFontName).isEmpty)
        #expect(FontCatalog.axisTag(FontCatalog.axisNumber("wght")) == "wght")
    }

    @Test func anAxisChangesTheLettersAndCanBeKeyframed() throws {
        let weight = try #require(FontCatalog.axes(of: "Skia-Regular").first { $0.tag == "wght" })
        func skia(_ value: Double?) -> CGRect {
            bounds(setting("Weight") {
                $0.fontName = "Skia-Regular"
                if let value { $0.variations = [.init(axis: "wght", value: value)] }
            })
        }
        #expect(skia(weight.maximum).width > skia(weight.minimum).width + 10)
        #expect(abs(skia(weight.defaultValue).width - skia(nil).width) < 0.5)

        var effect = Effect(kind: .text)
        effect.text = TextContent(string: "Weight", fontName: "Skia-Regular")
        let second = CMTime(seconds: 1, preferredTimescale: 600)
        effect.text?.changeVariation("wght", initial: weight.defaultValue) { value in
            value.setAnimated(true, at: .zero)
            value.set(weight.minimum, at: .zero)
            value.set(weight.maximum, at: second)
        }
        let start = try #require(TextOutline.Setting(effect, at: .zero))
        let end = try #require(TextOutline.Setting(effect, at: second))
        #expect(start.variations == [.init(axis: "wght", value: weight.minimum)])
        #expect(end.variations == [.init(axis: "wght", value: weight.maximum)])
    }

    @Test func anAxisIsAParameterLikeAControl() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let layer = project.addShapeLayer(.text, to: t)
        let text = try #require(layer)
        let second = CMTime(seconds: 1, preferredTimescale: 600)
        project.editClip(text.clipID, in: t) { clip in
            clip.effects[0].text?.fontName = "Skia-Regular"
            clip.effects[0].text?.changeVariation("wght", initial: 1) { value in
                value.setAnimated(true, at: .zero)
                value.set(2, at: second)
            }
        }
        let effectID = try #require(project.clipAndLayer(text.clipID, in: t)?.clip.effects.first?.id)
        let key = ParameterKey(timelineID: t, parameter: .textVariation(axis: "wght", clipID: text.clipID, effectID: effectID))
        // The graph editor reads and writes it as it does a control.
        let read = try #require(project.components(of: key))
        #expect(read.keyframes.map { $0.value.values } == [[1], [2]])
        #expect(project.timeAxis(of: key) != nil)
        #expect(project.parameterTitle(of: key) == "Text · Text · Weight")
        project.editComponents(of: key) { $0.set(ComponentValue(values: [3]), at: second) }
        let written = project.clipAndLayer(text.clipID, in: t)?.clip.effects.first?.text?.variations.first?.value
        #expect(written?.value(at: second) == 3)

        // Its keyframes are animation the render cache redraws, and F9
        // eases them.
        var clip = try #require(project.clipAndLayer(text.clipID, in: t)?.clip)
        #expect(clip.animatedSourceRanges.contains(.zero...second))
        let before = clip.effects[0].text?.variations.first?.value.keyframes.last
        let eased = clip.easeKeyframes(atTimelineTime: second, .easeIn)
        #expect(eased)
        #expect(clip.effects[0].text?.variations.first?.value.keyframes.last != before)
    }

    @Test func savingKeepsAxesAndTheirKeyframes() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let text = try fixture.addShape(.text)
        fixture.project.editClip(text.clipID, in: fixture.timelineID) { clip in
            clip.effects[0].text?.fontName = "Skia-Regular"
            clip.effects[0].text?.changeVariation("wght", initial: 1) { value in
                value.setAnimated(true, at: .zero)
                value.set(2, at: CMTime(seconds: 1, preferredTimescale: 600))
            }
            clip.effects[0].text?.changeVariation("wdth", initial: 1) { $0.set(0.8, at: .zero) }
        }
        let package = fixture.directory.appending(path: "Axes.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(fixture.project, to: package)
        let loaded = try await ProjectStore.load(from: package)
        let saved = try #require(fixture.project.clipAndLayer(text.clipID, in: fixture.timelineID)?.clip)
        let read = try #require(loaded.project.clipAndLayer(text.clipID, in: loaded.project.rootTimelineID)?.clip)
        #expect(read.effects == saved.effects)
        #expect(read.effects.first?.text?.variations.first?.value.isAnimated == true)
    }

    @Test func savingKeepsRuns() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let text = try fixture.addShape(.text)
        fixture.setText("Styled words", ofClip: text.clipID)
        fixture.project.editClip(text.clipID, in: fixture.timelineID) { clip in
            clip.effects[0].text?.changeStyle(in: NSRange(location: 0, length: 6)) { style in
                style = TextRunStyle(fixed: TextStyle(
                    fontName: "HelveticaNeue", size: 80, tracking: 20, baselineShift: 4, horizontalScale: 90, verticalScale: 110,
                    textCase: .allCaps, underline: true, strikethrough: false, fill: [1, 0, 0, 1], stroke: [0, 1, 0, 0.5],
                    kerning: -40, position: .subscript, strokeWidth: 3
                ))
                // Keyframed, a number and a color.
                style.size?.setAnimated(true, at: .zero)
                style.size?.set(120, at: CMTime(seconds: 1, preferredTimescale: 600))
                style.fill?.setAnimated(true, at: .zero)
                style.fill?.set(ComponentValue(values: [0, 0, 1, 1]), at: CMTime(seconds: 1, preferredTimescale: 600))
            }
        }
        let package = fixture.directory.appending(path: "Runs.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(fixture.project, to: package)
        let loaded = try await ProjectStore.load(from: package)
        let saved = try #require(fixture.project.clipAndLayer(text.clipID, in: fixture.timelineID)?.clip)
        let read = try #require(loaded.project.clipAndLayer(text.clipID, in: loaded.project.rootTimelineID)?.clip)
        #expect(read.effects == saved.effects)
        #expect(read.effects.first?.text?.runs.count == 1)
    }

    // MARK: Layout

    @Test func aBlockIsCenteredOnItsPosition() {
        let box = bounds(setting("Hello"))
        #expect(!box.isEmpty)
        #expect(abs(box.midX) < 6)
        // Cap height above the baseline and no descenders: the letters sit
        // a little above the block's middle, but cover it.
        #expect(box.minY < 0 && box.maxY > 0)
    }

    @Test func lineBreaksStackLinesALeadingApart() {
        let one = bounds(setting("Hello"))
        let two = bounds(setting("Hello\nHello"))
        let spaced = bounds(setting("Hello\nHello") { $0.leading = 300 })
        // Auto leading is 120% of the size.
        #expect(abs(two.height - one.height - 120) < 0.5)
        #expect(abs(spaced.height - one.height - 300) < 0.5)
        #expect(abs(two.width - one.width) < 1)
    }

    @Test func spaceBeforeAndAfterSeparateParagraphs() {
        let plain = bounds(setting("A\nB"))
        let spaced = bounds(setting("A\nB") { $0.spaceAfter = 50; $0.spaceBefore = 30 })
        #expect(abs(spaced.height - plain.height - 80) < 0.5)
        // Lines of one wrapped paragraph aren't spaced.
        let wrapped = setting("one two three four") { $0.wrapWidth = 250 }
        var spacedWrap = wrapped
        spacedWrap.spaceAfter = 50
        #expect(bounds(wrapped) == bounds(spacedWrap))
    }

    @Test func wrappingSetsAParagraphOnSeveralLines() {
        let words = "one two three four five six"
        let unwrapped = bounds(setting(words))
        let wrapped = bounds(setting(words) { $0.wrapWidth = 400 })
        #expect(wrapped.width <= 400)
        #expect(wrapped.width < unwrapped.width)
        #expect(wrapped.height > unwrapped.height * 2)
    }

    @Test func alignmentPutsLinesAgainstTheWrapWidthsEdges() {
        func aligned(_ align: TextAlign) -> CGRect { bounds(setting("Hi") { $0.wrapWidth = 600; $0.align = align }) }
        let left = aligned(.left), center = aligned(.center), right = aligned(.right)
        // Within a side bearing of the box's edge, 300 pixels from its middle.
        #expect(abs(left.minX + 300) < 15)
        #expect(abs(right.maxX - 300) < 15)
        #expect(abs(center.midX) < 6)
    }

    @Test func justifiedLinesSpanTheWrapWidthButTheLast() {
        let words = "one two three four five six seven eight nine ten"
        let left = bounds(setting(words) { $0.wrapWidth = 500; $0.align = .left })
        let justified = bounds(setting(words) { $0.wrapWidth = 500; $0.align = .justified })
        #expect(justified.width > 485)
        #expect(justified.width <= 501)
        #expect(left.width < justified.width)
        // Unwrapped, every line ends its paragraph, so it lines up left.
        let one = setting("Hi") { $0.align = .justified }
        var asLeft = one
        asLeft.align = .left
        #expect(bounds(one) == bounds(asLeft))
    }

    @Test func eachJustificationPlacesTheLastLineAsItSays() {
        // One wrapped line, which is its paragraph's last.
        func aligned(_ align: TextAlign) -> CGRect { bounds(setting("a b") { $0.wrapWidth = 500; $0.align = align }) }
        #expect(abs(aligned(.justified).minX + 250) < 15)
        #expect(abs(aligned(.justifyRight).maxX - 250) < 15)
        #expect(abs(aligned(.justifyCenter).midX) < 6)
        #expect(aligned(.justifyAll).width > 470)
    }

    @Test func indentsMoveLinesInFromTheEdges() {
        let left = bounds(setting("Hi") { $0.wrapWidth = 600; $0.align = .left; $0.leftIndent = 50 })
        let right = bounds(setting("Hi") { $0.wrapWidth = 600; $0.align = .right; $0.rightIndent = 50 })
        #expect(abs(left.minX + 250) < 15)
        #expect(abs(right.maxX - 250) < 15)
        // A first line hung out past the others.
        let hung = bounds(setting("one two three four five") {
            $0.wrapWidth = 600; $0.align = .left; $0.leftIndent = 100; $0.firstLineIndent = -100
        })
        let indented = bounds(setting("one two three four five") { $0.wrapWidth = 600; $0.align = .left; $0.leftIndent = 100 })
        #expect(abs(hung.minX + 300) < 15)
        #expect(abs(indented.minX + 200) < 15)
    }

    @Test func trackingSpreadsTheLetters() {
        let tight = bounds(setting("HHHHH"))
        // A fifth of an em, 20 pixels at this size.
        let spread = bounds(setting("HHHHH") { $0.tracking = 200 })
        // Four gaps between five letters.
        #expect(abs(spread.width - tight.width - 80) < 1)
        #expect(abs(spread.midX) < 6)
    }

    @Test func turningKerningOffLeavesThePairsApart() {
        let kerned = bounds(setting("AVAVAV"))
        let unkerned = bounds(setting("AVAVAV") { $0.kerning = .none })
        #expect(unkerned.width > kerned.width + 5)
    }

    @Test func scalingStretchesTheLetters() {
        let plain = bounds(setting("Hello"))
        let wide = bounds(setting("Hello") { $0.horizontalScale = 200 })
        let short = bounds(setting("Hello") { $0.verticalScale = 50 })
        #expect(abs(wide.width - plain.width * 2) < 2, "plain \(plain.width), wide \(wide.width)")
        #expect(abs(short.height - plain.height / 2) < 1)
        #expect(abs(short.width - plain.width) < 0.5)
    }

    @Test func baselineShiftRaisesAndRotationTurnsEachLetter() {
        let plain = bounds(setting("I"))
        let raised = bounds(setting("I") { $0.baselineShift = 30 })
        #expect(abs(raised.minY - (plain.minY - 30)) < 0.5)
        let turned = bounds(setting("I") { $0.characterRotation = 90 })
        #expect(plain.height > plain.width * 2)
        #expect(turned.width > turned.height * 2)
    }

    @Test func allCapsDrawsCapitalsWithoutChangingTheWords() {
        let caps = bounds(setting("hello") { $0.textCase = .allCaps })
        #expect(caps == bounds(setting("HELLO")))
        #expect(caps != bounds(setting("hello")))
    }

    @Test func underlineAndStrikethroughAreRules() {
        let plain = outline(setting("H"))
        let underlined = outline(setting("H") { $0.underline = true })
        let struck = outline(setting("H") { $0.strikethrough = true })
        // The underline sits below the baseline, under the H.
        #expect(underlined.boundingBoxOfPath.maxY > plain.boundingBoxOfPath.maxY + 2)
        #expect(struck != plain)
        #expect(abs(struck.boundingBoxOfPath.maxY - plain.boundingBoxOfPath.maxY) < 0.5)
    }

    @Test func openTypeSettingsTurnTheFontsFeaturesOnAndOff() {
        func tags(_ change: (inout TextOutline.Setting) -> Void) -> [String: Int] {
            let features = TextLayout.openTypeFeatures(for: setting("x", change))
            return Dictionary(features.map { ($0.tag, $0.on ? 1 : 0) }, uniquingKeysWith: { $1 })
        }
        #expect(tags { _ in }.isEmpty)
        #expect(tags { $0.ligatures = .none } == ["liga": 0, "clig": 0])
        #expect(tags { $0.ligatures = .all } == ["dlig": 1])
        #expect(tags { $0.textCase = .allSmallCaps } == ["smcp": 1, "c2sc": 1])
        #expect(tags { $0.figures = .tabularOldstyle } == ["tnum": 1, "onum": 1])
        #expect(tags { $0.stylisticSet = 3; $0.fractions = true } == ["ss03": 1, "frac": 1])
        #expect(tags { $0.contextualAlternates = false } == ["calt": 0])
        #expect(tags { $0.ordinals = true; $0.swash = true; $0.stylisticAlternates = true } == ["ordn": 1, "swsh": 1, "salt": 1])

        // Core Text keeps the ones the font has: Hoefler Text's
        // discretionary ligatures, and no font's unknown ones.
        let hoefler = TextLayout.font(for: setting("x") { $0.fontName = "HoeflerText-Regular"; $0.ligatures = .all })
        let kept = CTFontCopyFeatureSettings(hoefler) as? [[CFString: Any]] ?? []
        #expect(kept.contains { $0[kCTFontOpenTypeFeatureTag] as? String == "dlig" })
    }

    @Test func aSettingReadsTheEffectsControls() throws {
        var effect = Effect(kind: .text)
        effect.changeControl(.leading) { $0.setComponent(0, to: 150, at: .zero) }
        effect.changeControl(.textCase) { $0.choice = TextCase.smallCaps.rawValue }
        effect.changeControl(.underline) { $0.choice = OnOff.on.rawValue }
        effect.changeControl(.textAlign) { $0.choice = TextAlign.justifyAll.rawValue }
        effect.changeControl(.stylisticSet) { $0.setComponent(0, to: 25, at: .zero) }
        // Off: back to its default.
        effect.changeControl(.contextualAlternates) { $0.choice = OnOff.off.rawValue; $0.enabled = false }
        let read = try #require(TextOutline.Setting(effect, at: .zero))
        #expect(read.leading == 150)
        #expect(read.textCase == .smallCaps)
        #expect(read.underline)
        #expect(read.align == .justifyAll)
        #expect(read.stylisticSet == 20)
        #expect(read.contextualAlternates)
    }

    @Test func noWordsDrawNothing() {
        #expect(outline(setting("")).isEmpty)
        var effect = Effect(kind: .text)
        effect.text?.string = ""
        #expect(ShapeStep(effect, at: .zero, center: .zero) == nil)
    }

    @Test func aMissingFontStillDraws() {
        #expect(FontCatalog.isInstalled(TextContent.defaultFontName))
        #expect(!FontCatalog.isInstalled("NoSuchFont-Bold"))
        #expect(!bounds(setting("Hello") { $0.fontName = "NoSuchFont-Bold" }).isEmpty)
    }

    @Test func aFamilyListsItsStylesAndKeepsTheStyleWhenChanged() {
        #expect(FontCatalog.families().contains("Helvetica Neue"))
        let styles = FontCatalog.styles(ofFamily: "Helvetica Neue")
        #expect(styles.contains { $0.fontName == "HelveticaNeue-Bold" && $0.name == "Bold" })
        #expect(FontCatalog.fontName(inFamily: "Helvetica Neue", like: "Helvetica-Bold") == "HelveticaNeue-Bold")
        let shown = FontCatalog.familyAndStyle(of: "HelveticaNeue-Bold")
        #expect(shown.family == "Helvetica Neue")
        #expect(shown.style == "Bold")
    }

    // MARK: Drawing

    @Test func aTextLayerDrawsItsWordsOverBlack() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let text = try fixture.addShape(.text)
        // A bold I's stem covers the middle of the frame.
        fixture.setText("I", ofClip: text.clipID)
        fixture.setControl(.fontSize, [48], ofClip: text.clipID)

        let composed = try await fixture.build()
        #expect(composed.hasPictures)
        let stem = try await grayLevel(of: composed, at: second)
        let beside = try await grayLevel(of: composed, at: second, x: 0.3)
        #expect(stem > 220)
        #expect(beside < 10)
    }

    @Test func aNewTextLayerIsSizedToTheFrame() throws {
        var project = EditingProject.empty
        project.timelines[0].frameSize = CGSize(width: 1920, height: 1080)
        let layer = project.addShapeLayer(.text, to: project.rootTimelineID)
        let added = try #require(layer)
        let clip = try #require(project.clipAndLayer(added.clipID, in: project.rootTimelineID)?.clip)
        #expect(clip.effects.first?.control(.fontSize)?.values(at: .zero) == [120])
        #expect(clip.effects.first?.text == TextContent())
    }

    @Test func changingTheWordsChangesTheRenderButMovingTheClipDoesNot() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let text = try fixture.addShape(.text)

        let before = try await fixture.build().segments.filter(\.needsRender).map(\.key)
        fixture.project.editClip(text.clipID, in: fixture.timelineID) { $0.startOffset = CMTime(seconds: 1, preferredTimescale: 24) }
        let moved = try await fixture.build().segments.filter(\.needsRender).map(\.key)
        fixture.setText("Other", ofClip: text.clipID)
        let changed = try await fixture.build().segments.filter(\.needsRender).map(\.key)
        fixture.setText("Other", font: "HelveticaNeue", ofClip: text.clipID)
        let refonted = try await fixture.build().segments.filter(\.needsRender).map(\.key)
        #expect(!before.isEmpty)
        #expect(before == moved)
        #expect(Set(changed).isDisjoint(with: Set(before)))
        #expect(Set(refonted).isDisjoint(with: Set(changed)))
    }

    // MARK: Editing and saving

    @Test func savingKeepsTheWordsFontAndSettings() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let text = try fixture.addShape(.text)
        // A missing font is kept by name.
        fixture.setText("Line one\nLine \u{201C}two\u{201D} ✨", font: "NoSuchFont-Bold", ofClip: text.clipID)
        fixture.setChoice(.textAlign, TextAlign.justified.rawValue, ofClip: text.clipID)
        fixture.setControl(.wrapWidth, [300], ofClip: text.clipID)
        fixture.project.editClip(text.clipID, in: fixture.timelineID) { clip in
            clip.effects[0].changeControl(.fontSize) { size in
                size.number.setAnimated(true, at: .zero)
                size.setComponent(0, to: 60, at: CMTime(seconds: 1, preferredTimescale: 600))
            }
        }
        let package = fixture.directory.appending(path: "Text.amv", directoryHint: .isDirectory)

        try await ProjectStore.save(fixture.project, to: package)
        let loaded = try await ProjectStore.load(from: package)
        let saved = try #require(fixture.project.clipAndLayer(text.clipID, in: fixture.timelineID)?.clip)
        let read = try #require(loaded.project.clipAndLayer(text.clipID, in: loaded.project.rootTimelineID)?.clip)
        #expect(read.effects == saved.effects)
        #expect(read.effects.first?.text?.fontName == "NoSuchFont-Bold")
        #expect(read.effects.first?.control(.fontSize)?.isAnimated == true)
    }

    @Test func aTextClipIsNamedByItsFirstLine() throws {
        var project = EditingProject.empty
        let layer = project.addShapeLayer(.text, to: project.rootTimelineID)
        let added = try #require(layer)
        project.editClip(added.clipID, in: project.rootTimelineID) { $0.effects[0].text?.string = "  Hello  \nWorld" }
        let clip = try #require(project.clipAndLayer(added.clipID, in: project.rootTimelineID)?.clip)
        #expect(project.resolvedInfo(for: clip)?.name == "Hello")
        #expect(project.clipName(added.clipID, in: project.rootTimelineID) == "Hello")

        var shapes = EditingProject.empty
        let boxLayer = shapes.addShapeLayer(.rectangle, to: shapes.rootTimelineID)
        let box = try #require(boxLayer)
        let boxClip = try #require(shapes.clipAndLayer(box.clipID, in: shapes.rootTimelineID)?.clip)
        #expect(shapes.resolvedInfo(for: boxClip)?.name == "Shapes")
    }

    @Test func resetKeepsTheWordsAndFont() {
        var effect = Effect(kind: .text)
        effect.text = TextContent(string: "Kept", fontName: "HelveticaNeue")
        effect.changeControl(.fontSize) { $0.setComponent(0, to: 300, at: .zero) }
        effect.reset(in: CGSize(width: 1920, height: 1080))
        #expect(effect.text == TextContent(string: "Kept", fontName: "HelveticaNeue"))
        #expect(effect.control(.fontSize)?.values(at: .zero) == [120])
    }

    @Test func aTextWithNoWordsSaysSo() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let textLayer = project.addShapeLayer(.text, to: t)
        let added = try #require(textLayer)
        project.editClip(added.clipID, in: t) { $0.effects[0].text?.string = "" }
        let (clip, layer) = try #require(project.clipAndLayer(added.clipID, in: t))
        let timeline = try #require(project.timeline(id: t))
        #expect(project.note(forEffectAt: 0, in: clip, on: layer, of: timeline)?.dims == true)
    }
}
