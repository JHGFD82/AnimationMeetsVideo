import AppKit
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// Typing in the inspector ended by a click anywhere else, with real
/// events (see `EventHarness`; run with `UI_EVENTS=1`): on the panel's
/// background, a control, another panel or the bare window, none of which
/// take the keyboard, as well as on another field.
@MainActor
@Suite(.serialized, .enabled(if: EventHarness.isEnabled), .timeLimit(.minutes(1)))
struct ClickAwayEndsEditingTests {
    @MainActor @Observable
    final class Record {
        var words = TextContent(string: "Hello")
        var selection = NSRange(location: 0, length: 0)
        var name = "Blur"
        var committedNames: [String] = []
        var viewerTaps = 0
        var buttonPresses = 0
    }

    /// A field entered when it lets go of the keyboard, as an effect's
    /// name is (`EffectRows`).
    private struct NameField: View {
        let record: Record
        @State private var draft = "Blur"
        @FocusState private var focused: Bool

        var body: some View {
            TextField("Name", text: $draft)
                .focused($focused)
                .onChange(of: focused) { _, focused in
                    if !focused { record.committedNames.append(draft) }
                }
        }
    }

    /// A stand-in viewer, 200 by 200 from the top left, that counts its
    /// clicks; under it bare window. To its right a side panel, 300 wide
    /// from x 200: a Text effect's words (y 10 to 70), a name field (y 78
    /// to 100), a button (from y 108) and blank panel below.
    private struct Editor: View {
        let record: Record

        var body: some View {
            @Bindable var record = record
            HStack(alignment: .top, spacing: 0) {
                Color.gray
                    .frame(width: 200, height: 200)
                    .contentShape(Rectangle())
                    .onTapGesture { record.viewerTaps += 1 }
                VStack(alignment: .leading, spacing: 8) {
                    TextWordsEditor(content: record.words, selection: $record.selection) { record.words = $0 }
                        .frame(width: 280, height: 60)
                    NameField(record: record)
                        .frame(width: 200, height: 22)
                    Text("Apply")
                        .frame(width: 60, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { record.buttonPresses += 1 }
                    Spacer()
                }
                .padding(10)
                .frame(width: 300, height: 300, alignment: .topLeading)
                .endsEditingOnClickAway()
            }
        }
    }

    private func views<V: NSView>(of type: V.Type, in view: NSView?) -> [V] {
        guard let view else { return [] }
        return ((view as? V).map { [$0] } ?? []) + view.subviews.flatMap { views(of: type, in: $0) }
    }

    /// A press at `point` (from the top left), then the click. Local
    /// monitors aren't sent events that skip the event queue (and taking
    /// one from it ends the test process), so the panel's monitor is told
    /// of the press first, as it would be.
    private func click(at point: CGPoint, in harness: EventHarness) async throws {
        let location = CGPoint(x: point.x, y: harness.window.frame.height - point.y)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        for monitor in views(of: ClickAwayEndsEditing.MonitorView.self, in: harness.window.contentView) {
            monitor.pressed(event)
        }
        try await harness.click(at: point)
    }

    private func wordsView(_ harness: EventHarness) throws -> NSTextView {
        try #require(views(of: TextWordsEditor.WordsTextView.self, in: harness.window.contentView).first)
    }

    private func nameField(_ harness: EventHarness) throws -> NSTextField {
        try #require(views(of: NSTextField.self, in: harness.window.contentView).first { $0.isEditable })
    }

    /// Whether some text is being typed in.
    private func isEditing(_ harness: EventHarness) -> Bool {
        harness.window.firstResponder is NSTextView
    }

    /// Starts typing in the words, as a click into them would (a real
    /// click's tracking of the mouse ends the test process), and types.
    private func editWords(_ harness: EventHarness, typing text: String) async throws {
        let words = try wordsView(harness)
        harness.window.makeFirstResponder(words)
        words.setSelectedRange(NSRange(location: words.string.utf16.count, length: 0))
        words.insertText(text, replacementRange: words.selectedRange())
        try await harness.settle()
    }

    private func editName(_ harness: EventHarness, typing text: String) async throws {
        harness.window.makeFirstResponder(try nameField(harness))
        try await harness.settle()
        let editor = try #require(harness.window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        try await harness.settle()
    }

    @Test func clickingAnywhereElseEndsTypingTheWords() async throws {
        let record = Record()
        let harness = EventHarness(Editor(record: record), size: CGSize(width: 500, height: 300))
        // The panel's blank background, the viewer, the bare window under
        // it, and the button.
        let elsewhere = [CGPoint(x: 400, y: 250), CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 260), CGPoint(x: 240, y: 119)]
        for (index, point) in elsewhere.enumerated() {
            try await editWords(harness, typing: "\(index)")
            #expect(isEditing(harness))
            try await click(at: point, in: harness)
            #expect(!isEditing(harness))
        }
        #expect(record.words.string == "Hello0123")
        // The clicks still went where they were aimed.
        #expect(record.viewerTaps == 1)
        #expect(record.buttonPresses == 1)
    }

    @Test func clickingAnywhereElseEntersTheName() async throws {
        let record = Record()
        let harness = EventHarness(Editor(record: record), size: CGSize(width: 500, height: 300))
        try await editName(harness, typing: "Glow")
        try await click(at: CGPoint(x: 400, y: 250), in: harness)
        #expect(!isEditing(harness))
        try await editName(harness, typing: "Haze")
        try await click(at: CGPoint(x: 100, y: 100), in: harness)
        #expect(!isEditing(harness))
        #expect(record.committedNames == ["Glow", "Haze"])
        #expect(record.viewerTaps == 1)
    }

    @Test func clicksInTheTextBeingEditedKeepIt() async throws {
        let record = Record()
        let harness = EventHarness(Editor(record: record), size: CGSize(width: 500, height: 300))
        try await editWords(harness, typing: "!")
        let words = try wordsView(harness)
        // Only the monitor: a real click's tracking ends the test process.
        let location = CGPoint(x: 300, y: harness.window.frame.height - 30)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        for monitor in views(of: ClickAwayEndsEditing.MonitorView.self, in: harness.window.contentView) {
            monitor.pressed(event)
        }
        #expect(harness.window.firstResponder === words)
    }

    @Test func clickingAnotherFieldMovesTheTypingThere() async throws {
        let record = Record()
        let harness = EventHarness(Editor(record: record), size: CGSize(width: 500, height: 300))
        try await editWords(harness, typing: "!")
        let location = CGPoint(x: 300, y: harness.window.frame.height - 89)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        for monitor in views(of: ClickAwayEndsEditing.MonitorView.self, in: harness.window.contentView) {
            monitor.pressed(event)
        }
        // What the click itself then does (see `editWords`).
        harness.window.makeFirstResponder(try nameField(harness))
        try await harness.settle()
        let editor = try #require(harness.window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        #expect(record.words.string == "Hello!")
    }
}
