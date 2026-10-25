import CoreGraphics
import CoreMedia
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
        var setting = TextOutline.Setting(
            string: string, fontName: TextContent.defaultFontName, size: 100, tracking: 0, lineHeight: 100, wrapWidth: 0,
            align: .center
        )
        change(&setting)
        return setting
    }

    private func bounds(_ setting: TextOutline.Setting) -> CGRect {
        TextLayout.layOut(setting).boundingBoxOfPath
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

    @Test func lineBreaksStackLinesDownward() {
        let one = bounds(setting("Hello"))
        let two = bounds(setting("Hello\nHello"))
        let spaced = bounds(setting("Hello\nHello") { $0.lineHeight = 200 })
        #expect(two.height > one.height * 1.8)
        #expect(spaced.height > two.height * 1.5)
        #expect(abs(two.width - one.width) < 1)
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

    @Test func trackingSpreadsTheLetters() {
        let tight = bounds(setting("HHHHH"))
        let spread = bounds(setting("HHHHH") { $0.tracking = 20 })
        // Four gaps between five letters.
        #expect(abs(spread.width - tight.width - 80) < 1)
    }

    @Test func noWordsDrawNothing() {
        #expect(TextLayout.layOut(setting("")).isEmpty)
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
