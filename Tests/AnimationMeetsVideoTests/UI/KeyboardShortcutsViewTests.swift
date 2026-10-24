import Testing
@testable import AnimationMeetsVideo

@MainActor
struct KeyboardShortcutsViewTests {
    @Test func modifiersAndGlyphsAreNamed() {
        #expect(KeyboardShortcutsView.spokenKeys("⇧⌘B") == "Shift Command B")
        #expect(KeyboardShortcutsView.spokenKeys("⌃⌥H") == "Control Option H")
        #expect(KeyboardShortcutsView.spokenKeys("⌥← ⌥→") == "Option Left Arrow, Option Right Arrow")
    }

    @Test func eachKeyOfARowIsSeparated() {
        #expect(KeyboardShortcutsView.spokenKeys("= −") == "Equals, Minus")
        #expect(KeyboardShortcutsView.spokenKeys(", .") == "Comma, Period")
        #expect(KeyboardShortcutsView.spokenKeys("A B Y") == "A, B, Y")
        #expect(KeyboardShortcutsView.spokenKeys("⇧F9  ⇧⌘F9") == "Shift F9, Shift Command F9")
    }

    @Test func namedKeysReadAsThemselves() {
        #expect(KeyboardShortcutsView.spokenKeys("Space") == "Space")
        #expect(KeyboardShortcutsView.spokenKeys("⌫") == "Delete")
        #expect(KeyboardShortcutsView.spokenKeys("Esc") == "Escape")
        #expect(KeyboardShortcutsView.spokenKeys("\\") == "Backslash")
    }

    @Test func everyGlyphInTheWindowHasAName() {
        // A glyph left unnamed would be read as a symbol or skipped.
        let glyphs = Set("←→↑↓⌘⇧⌥⌃⌫=−\\")
        for group in KeyboardShortcutsView.groups {
            for shortcut in group.shortcuts {
                let spoken = KeyboardShortcutsView.spokenKeys(shortcut.keys)
                #expect(!spoken.contains(where: glyphs.contains), "\(shortcut.keys) reads as \(spoken)")
            }
        }
    }
}
