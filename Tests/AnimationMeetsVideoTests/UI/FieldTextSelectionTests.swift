import AppKit
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// Fields clicked into, values clicked to type and names renamed, with
/// real events (see `EventHarness`; run with `UI_EVENTS=1`): each starts
/// with its whole value selected (`FieldTextSelection`).
@MainActor
@Suite(.serialized, .enabled(if: EventHarness.isEnabled), .timeLimit(.minutes(1)))
struct FieldTextSelectionTests {
    @MainActor @Observable
    final class Renaming {
        var isEditing = false
        var committed: [String] = []
    }

    /// A plain field 200 points wide along the top.
    private struct Fields: View {
        @State private var name = "Opening titles"

        var body: some View {
            TextField("Name", text: $name)
                .frame(width: 200, height: 24)
        }
    }

    /// A value to click, from (10, 10).
    private struct Value: View {
        var body: some View {
            NumericField(value: 125, onCommit: { _ in })
                .padding(10)
        }
    }

    private struct Name: View {
        let renaming: Renaming

        var body: some View {
            @Bindable var renaming = renaming
            InlineNameField(name: "Chorus", isEditing: $renaming.isEditing, onCommit: { renaming.committed.append($0) })
                .frame(width: 200, alignment: .leading)
                .padding(10)
        }
    }

    private func harness(_ view: some View) -> EventHarness {
        let harness = EventHarness(view, size: CGSize(width: 300, height: 120))
        FieldTextSelection.watch(harness.window)
        return harness
    }

    private func editor(_ harness: EventHarness) -> NSTextView? {
        (harness.window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
    }

    /// What a click on the plain field does: it starts being edited, and
    /// the click's tracking leaves the caret where it landed. A real click
    /// can't be sent here: a field editor's tracking of the mouse stops the
    /// main run loop when `NSApp` was never `run()`, which ends the test
    /// process.
    private func clickIntoField(_ harness: EventHarness) throws {
        let field = try #require(Self.field(in: harness.window.contentView))
        harness.window.makeFirstResponder(field)
        editor(harness)?.setSelectedRange(NSRange(location: 4, length: 0))
    }

    /// A key pressed in the field being edited. `EventHarness.key` goes
    /// through the window, which, borderless, never becomes key, so it
    /// doesn't pass keys to the field editor.
    private func type(code: UInt16, characters: String, into editor: NSTextView, of harness: EventHarness) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        ) else { return }
        editor.keyDown(with: event)
    }

    private static func field(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { field(in: $0) }.first
    }

    @Test func clickingIntoAFieldSelectsItsWholeValue() async throws {
        let harness = harness(Fields())
        defer { FieldTextSelection.unwatch(harness.window) }
        harness.window.makeFirstResponder(nil)
        try clickIntoField(harness)
        try await harness.settle()
        let editor = try #require(editor(harness))
        #expect(editor.string == "Opening titles")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 14))
    }

    @Test func aSecondClickInTheFieldPlacesTheCaret() async throws {
        let harness = harness(Fields())
        defer { FieldTextSelection.unwatch(harness.window) }
        harness.window.makeFirstResponder(nil)
        try clickIntoField(harness)
        try await harness.settle()
        // A second click moves the caret without changing first responder.
        let editor = try #require(editor(harness))
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        try await harness.settle()
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test func clickingAValueToTypeSelectsIt() async throws {
        let harness = harness(Value())
        defer { FieldTextSelection.unwatch(harness.window) }
        try await harness.click(at: CGPoint(x: 16, y: 18))
        let editor = try #require(editor(harness))
        #expect(editor.string == "125")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 3))
    }

    @Test func renamingSelectsTheWholeName() async throws {
        let renaming = Renaming()
        let harness = harness(Name(renaming: renaming))
        defer { FieldTextSelection.unwatch(harness.window) }
        renaming.isEditing = true
        try await harness.settle(250)
        let editor = try #require(editor(harness))
        #expect(editor.string == "Chorus")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 6))
    }

    @Test func escapeAfterTypingOverTheNamePutsItBack() async throws {
        let renaming = Renaming()
        let harness = harness(Name(renaming: renaming))
        defer { FieldTextSelection.unwatch(harness.window) }
        renaming.isEditing = true
        try await harness.settle(250)
        let editor = try #require(editor(harness))
        type(code: 7, characters: "x", into: editor, of: harness)
        try await harness.settle()
        #expect(editor.string == "x")
        type(code: 53, characters: "\u{1b}", into: editor, of: harness)
        try await harness.settle(250)
        #expect(!renaming.isEditing)
        #expect(renaming.committed.isEmpty)
    }
}
