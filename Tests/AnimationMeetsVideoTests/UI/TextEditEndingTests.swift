import AppKit
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// A press outside the text being edited ends the edit, with real windows
/// (see `EventHarness`; run with `UI_EVENTS=1`). The presses are handed to
/// `TextEditEnding` directly: local monitors aren't sent events that skip
/// the event queue.
@MainActor
@Suite(.serialized, .enabled(if: EventHarness.isEnabled), .timeLimit(.minutes(1)))
struct TextEditEndingTests {
    @MainActor @Observable
    final class Words {
        var content = TextContent()
        var selection = NSRange(location: 0, length: 0)
    }

    /// A Text layer's words along the top, 80 high, over empty space that
    /// takes no focus, as the timeline doesn't.
    private struct WordsBox: View {
        let words: Words

        var body: some View {
            @Bindable var words = words
            VStack(spacing: 0) {
                TextWordsEditor(content: words.content, selection: $words.selection) { words.content = $0 }
                    .frame(width: 260, height: 80)
                Color.clear
            }
        }
    }

    private struct Field: View {
        @State private var name = "Opening titles"

        var body: some View {
            TextField("Name", text: $name)
                .frame(width: 200, height: 24)
        }
    }

    private func press(_ type: NSEvent.EventType = .leftMouseDown, at point: CGPoint, in harness: EventHarness) {
        let location = CGPoint(x: point.x, y: harness.window.frame.height - point.y)
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        TextEditEnding.pressed(event)
    }

    private static func view<V: NSView>(_ type: V.Type, in view: NSView?) -> V? {
        guard let view else { return nil }
        if let found = view as? V { return found }
        return view.subviews.lazy.compactMap { Self.view(type, in: $0) }.first
    }

    private func wordsView(_ harness: EventHarness) throws -> NSTextView {
        try #require(Self.view(TextWordsEditor.WordsTextView.self, in: harness.window.contentView))
    }

    @Test func aPressBelowTheWordsEndsTheirEditAndKeepsTheSelection() async throws {
        let words = Words()
        words.content.replaceString(with: "Hello world")
        let harness = EventHarness(WordsBox(words: words), size: CGSize(width: 300, height: 200))
        try await harness.settle()
        let text = try wordsView(harness)
        harness.window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 6, length: 5))
        try await harness.settle()

        press(at: CGPoint(x: 150, y: 160), in: harness)
        try await harness.settle()
        #expect(!(harness.window.firstResponder is NSText))
        // Character still styles the letters picked.
        #expect(words.selection == NSRange(location: 6, length: 5))
        #expect(text.selectedRange() == NSRange(location: 6, length: 5))
    }

    @Test func aPressInTheWordsKeepsEditingThem() async throws {
        let words = Words()
        words.content.replaceString(with: "Hello world")
        let harness = EventHarness(WordsBox(words: words), size: CGSize(width: 300, height: 200))
        try await harness.settle()
        let text = try wordsView(harness)
        harness.window.makeFirstResponder(text)
        press(at: CGPoint(x: 40, y: 20), in: harness)
        press(.rightMouseDown, at: CGPoint(x: 40, y: 20), in: harness)
        #expect(harness.window.firstResponder === text)
    }

    @Test func aRightClickElsewhereEndsAFieldsEdit() async throws {
        let harness = EventHarness(Field(), size: CGSize(width: 300, height: 120))
        try await harness.settle()
        let field = try #require(Self.view(NSTextField.self, in: harness.window.contentView))
        harness.window.makeFirstResponder(field)
        #expect(TextEditEnding.editedView(in: harness.window) === field)
        // In the field: the edit stays.
        press(at: CGPoint(x: 20, y: 12), in: harness)
        #expect(TextEditEnding.editedView(in: harness.window) === field)
        press(.rightMouseDown, at: CGPoint(x: 150, y: 100), in: harness)
        #expect(TextEditEnding.editedView(in: harness.window) == nil)
    }
}
