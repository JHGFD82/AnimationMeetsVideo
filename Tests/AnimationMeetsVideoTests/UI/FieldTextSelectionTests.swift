import CoreMedia
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

    @MainActor @Observable
    final class Playhead {
        var time = CMTime.zero
    }

    /// A music track's volume to click, from (10, 10). It is drawn again
    /// as the playhead moves, as skimming the timeline moves it.
    private struct Volume: View {
        let playhead: Playhead

        var body: some View {
            AudioPropertyRow(value: AnimatedValue(-6.0), time: playhead.time, onEdit: { _ in }, onSeek: { _ in })
                .frame(width: 280, alignment: .leading)
                .padding(10)
        }
    }

    /// A music layer's header, never renamed, from (10, 10), 28 high.
    private struct LayerHeader: View {
        let renaming: Renaming

        var body: some View {
            LayerHeaderRow(
                number: 1, layer: TimelineLayer(customName: nil, kind: .music, clips: []), displayName: "Music 1",
                height: 28, canMoveUp: false, canMoveDown: false,
                isExpanded: nil, onToggleExpanded: {},
                isAudioExpanded: nil, onToggleAudio: {}, onDetachAudio: {},
                isChannelsExpanded: nil, onToggleChannels: {},
                onRename: { renaming.committed.append($0 ?? "") }, onMove: { _ in },
                onDragChanged: { _ in }, onDragEnded: { _ in },
                isSelected: false, onSelect: {}, onDelete: {}
            )
            .frame(width: 260)
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

    /// What a click at `point` (from the top left) on a field already being
    /// edited does: `FieldTextSelection` sees it before the window, then
    /// the click's tracking puts the caret where it landed. Its local
    /// monitor isn't sent events that skip the event queue, so it's told.
    private func click(at point: CGPoint, inEdited harness: EventHarness) {
        let location = CGPoint(x: point.x, y: harness.window.frame.height - point.y)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        FieldTextSelection.mouseDown(event)
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

    @Test func firstClickOnAFieldAlreadyBeingEditedSelectsItsWholeValue() async throws {
        let harness = harness(Fields())
        defer { FieldTextSelection.unwatch(harness.window) }
        // As when its sheet opened, or Tab moved to it.
        let field = try #require(Self.field(in: harness.window.contentView))
        harness.window.makeFirstResponder(field)
        try await harness.settle()
        let editor = try #require(editor(harness))
        editor.setSelectedRange(NSRange(location: 14, length: 0))
        click(at: CGPoint(x: 100, y: 12), inEdited: harness)
        try await harness.settle()
        #expect(editor.selectedRange() == NSRange(location: 0, length: 14))
        // The next click places the caret.
        click(at: CGPoint(x: 100, y: 12), inEdited: harness)
        try await harness.settle()
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test func clickingBackIntoAFieldAfterClickingAwaySelectsItsWholeValue() async throws {
        let harness = harness(Fields())
        defer { FieldTextSelection.unwatch(harness.window) }
        let field = try #require(Self.field(in: harness.window.contentView))
        harness.window.makeFirstResponder(field)
        try await harness.settle()
        let editor = try #require(editor(harness))
        click(at: CGPoint(x: 100, y: 12), inEdited: harness)
        try await harness.settle()
        click(at: CGPoint(x: 100, y: 12), inEdited: harness)
        try await harness.settle()
        // A click below the field, on nothing that takes focus.
        click(at: CGPoint(x: 100, y: 90), inEdited: harness)
        try await harness.settle()
        #expect(harness.window.firstResponder === editor)
        click(at: CGPoint(x: 100, y: 12), inEdited: harness)
        try await harness.settle()
        #expect(editor.selectedRange() == NSRange(location: 0, length: 14))
    }

    @Test func clickingAValueToTypeSelectsIt() async throws {
        let harness = harness(Value())
        defer { FieldTextSelection.unwatch(harness.window) }
        try await harness.click(at: CGPoint(x: 16, y: 18))
        let editor = try #require(editor(harness))
        #expect(editor.string == "125")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 3))
    }

    @Test func aVolumeOpenedToTypeStaysSelectedAsThePlayheadMoves() async throws {
        let playhead = Playhead()
        let harness = harness(Volume(playhead: playhead))
        defer { FieldTextSelection.unwatch(harness.window) }
        try await harness.click(at: CGPoint(x: 100, y: 18))
        let editor = try #require(editor(harness))
        #expect(editor.string == "-6")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 2))
        playhead.time = CMTime(value: 1, timescale: 2)
        try await harness.settle()
        #expect(editor.selectedRange() == NSRange(location: 0, length: 2))
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

    /// The first click and the second of a double-click at `point`.
    private func doubleClick(at point: CGPoint, in harness: EventHarness) async throws {
        let location = CGPoint(x: point.x, y: harness.window.frame.height - point.y)
        for clickCount in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                    pressure: type == .leftMouseUp ? 0 : 1
                ) else { continue }
                NSApp.sendEvent(event)
                try await harness.settle(20)
            }
        }
        try await harness.settle(250)
    }

    @Test func renamingALayerWithItsDefaultNameSelectsThatName() async throws {
        let renaming = Renaming()
        let harness = harness(LayerHeader(renaming: renaming))
        defer { FieldTextSelection.unwatch(harness.window) }
        try await doubleClick(at: CGPoint(x: 75, y: 24), in: harness)
        let editor = try #require(editor(harness))
        #expect(editor.string == "Music 1")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 7))
        // Left as it was, the default name isn't made the layer's own.
        harness.window.makeFirstResponder(nil)
        try await harness.settle(250)
        #expect(renaming.committed.isEmpty)
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
