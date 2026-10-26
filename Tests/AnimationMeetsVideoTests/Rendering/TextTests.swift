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
        content.changeStyle(in: NSRange(location: 6, length: 5)) { $0.size = 200 }
        #expect(content.runs == [TextRun(start: 6, length: 5, style: TextStyle(size: 200))])
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
        content.changeStyle(in: NSRange(location: 3, length: 3)) { $0.tracking = 50 }
        #expect(content.runs == [
            TextRun(start: 0, length: 3, style: TextStyle(underline: true)),
            TextRun(start: 3, length: 1, style: TextStyle(tracking: 50, underline: true)),
            TextRun(start: 4, length: 2, style: TextStyle(tracking: 50)),
        ])
    }

    @Test func aRunSetsItsLettersApartFromTheBlock() {
        let plain = setting("HHHH")
        var bigger = plain
        bigger.runs = [TextRun(start: 2, length: 2, style: TextStyle(size: 200))]
        // The two big letters are twice as wide and the block as tall as them.
        let small = bounds(plain), mixed = bounds(bigger)
        #expect(abs(mixed.width - small.width * 1.5) < 4)
        #expect(mixed.height > small.height * 1.8)

        var shifted = plain
        shifted.runs = [TextRun(start: 0, length: 1, style: TextStyle(baselineShift: 40))]
        #expect(abs(bounds(shifted).minY - (small.minY - 40)) < 0.5)

        var wide = plain
        wide.runs = [TextRun(start: 0, length: 4, style: TextStyle(horizontalScale: 200))]
        #expect(abs(bounds(wide).width - small.width * 2) < 4)

        var capped = setting("hello")
        capped.runs = [TextRun(start: 0, length: 5, style: TextStyle(textCase: .allCaps))]
        #expect(bounds(capped) == bounds(setting("HELLO")))
    }

    @Test func aRunsColorsPaintItsLetters() {
        var styled = setting("ab")
        styled.runs = [TextRun(start: 1, length: 1, style: TextStyle(fill: [1, 0, 0, 1], stroke: [0, 0, 1, 1]))]
        let drawn = pieces(styled)
        #expect(drawn.count == 2)
        #expect(drawn.map(\.fill) == [[1, 1, 1, 1], [1, 0, 0, 1]])
        #expect(drawn.map(\.stroke) == [[0, 0, 0, 1], [0, 0, 1, 1]])
        // Without a block fill, a run's color doesn't add one.
        #expect(TextOutline(setting: styled, center: .zero).pieces(fill: nil, stroke: nil).allSatisfy { $0.fill == nil && $0.stroke == nil })
    }

    @Test func aRunCanUnderlineSomeLetters() {
        var styled = setting("HHHH")
        styled.runs = [TextRun(start: 0, length: 2, style: TextStyle(underline: true))]
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
        kerned.runs = [TextRun(start: 0, length: 1, style: TextStyle(kerning: 200))]
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
        raised.runs = [TextRun(start: 0, length: 1, style: TextStyle(position: .superscript))]
        var lowered = raised
        lowered.runs[0].style.position = .subscript
        let up = bounds(raised), down = bounds(lowered)
        #expect(abs(up.height - plain.height * TextPosition.syntheticSize) < 1)
        #expect(down.height == up.height)
        // Beside an ordinary H, its baseline is 33.3 pixels up or down.
        func baselines(_ position: TextPosition) -> (plain: CGFloat, moved: CGFloat) {
            var pair = setting("HH")
            pair.runs = [TextRun(start: 1, length: 1, style: TextStyle(position: position))]
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

    @Test func savingKeepsRuns() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let text = try fixture.addShape(.text)
        fixture.setText("Styled words", ofClip: text.clipID)
        fixture.project.editClip(text.clipID, in: fixture.timelineID) { clip in
            clip.effects[0].text?.changeStyle(in: NSRange(location: 0, length: 6)) { style in
                style = TextStyle(
                    fontName: "HelveticaNeue", size: 80, tracking: 20, baselineShift: 4, horizontalScale: 90, verticalScale: 110,
                    textCase: .allCaps, underline: true, strikethrough: false, fill: [1, 0, 0, 1], stroke: [0, 1, 0, 0.5],
                    kerning: -40, position: .subscript
                )
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
