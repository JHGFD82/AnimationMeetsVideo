import AppKit
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Selecting a whole line of a Text effect's words in the inspector.
@MainActor @Suite struct TextWordsEditorTests {
    @Test func aTripleClickedLineIsSelectedWithoutItsBreak() {
        let view = TextWordsEditor.WordsTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.string = "First line\nSecond line\nThird"
        // A click in "Second", taken out to its paragraph.
        let picked = view.selectionRange(forProposedRange: NSRange(location: 13, length: 0), granularity: .selectByParagraph)
        #expect(picked == NSRange(location: 11, length: 11))
        // Typed over, the line stays one of its own.
        view.setSelectedRange(picked)
        view.insertText("Changed", replacementRange: picked)
        #expect(view.string == "First line\nChanged\nThird")
        // Words are still taken with what follows them.
        let word = view.selectionRange(forProposedRange: NSRange(location: 2, length: 0), granularity: .selectByWord)
        #expect(word == NSRange(location: 0, length: 5))
    }

    @Test func onlyASingleLineLosesItsBreak() {
        let string = "ab\ncd\r\nef\n" as NSString
        #expect(TextWordsEditor.withoutLineBreak(NSRange(location: 0, length: 3), in: string) == NSRange(location: 0, length: 2))
        // CR LF goes as one break.
        #expect(TextWordsEditor.withoutLineBreak(NSRange(location: 3, length: 4), in: string) == NSRange(location: 3, length: 2))
        // Several lines, the break alone, or a line with no break are kept.
        #expect(TextWordsEditor.withoutLineBreak(NSRange(location: 0, length: 7), in: string) == NSRange(location: 0, length: 7))
        #expect(TextWordsEditor.withoutLineBreak(NSRange(location: 2, length: 1), in: string) == NSRange(location: 2, length: 1))
        #expect(TextWordsEditor.withoutLineBreak(NSRange(location: 7, length: 2), in: string) == NSRange(location: 7, length: 2))
    }
}
