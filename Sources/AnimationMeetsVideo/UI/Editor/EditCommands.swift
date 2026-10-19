import AppKit
import SwiftUI

/// What Cut, Copy, Paste, Duplicate and Delete in the Edit menu do for
/// what is selected in one part of the editor, which publishes it with
/// `focusedSceneValue`. A nil command leaves it to the next part (see
/// `EditCommands`).
struct EditMenuActions {
    var cut: (() -> Void)?
    var copy: (() -> Void)?
    var paste: (() -> Void)?
    var duplicate: (() -> Void)?
    var delete: (() -> Void)?
    /// What the commands act on, such as the selection and what was copied:
    /// sets with the same `state` and the same commands do the same.
    var state: AnyHashable
}

extension EditMenuActions: Equatable {
    /// Closures don't compare; the state they act on and which of them
    /// there are does. A new set for every redraw would rebuild the menu
    /// bar on every redraw.
    nonisolated static func == (lhs: EditMenuActions, rhs: EditMenuActions) -> Bool {
        lhs.state == rhs.state && lhs.offered == rhs.offered
    }

    private nonisolated var offered: [Bool] {
        [cut != nil, copy != nil, paste != nil, duplicate != nil, delete != nil]
    }
}

private struct BeatMatchEditKey: FocusedValueKey { typealias Value = EditMenuActions }
private struct EffectsEditKey: FocusedValueKey { typealias Value = EditMenuActions }
private struct TimelineEditKey: FocusedValueKey { typealias Value = EditMenuActions }

extension FocusedValues {
    /// Beat Match's beats and sections, while it is open.
    var beatMatchEditActions: EditMenuActions? {
        get { self[BeatMatchEditKey.self] }
        set { self[BeatMatchEditKey.self] = newValue }
    }

    /// The effects panel's effects, while it shows a clip.
    var effectsEditActions: EditMenuActions? {
        get { self[EffectsEditKey.self] }
        set { self[EffectsEditKey.self] = newValue }
    }

    /// The timeline's clips, layers and sections.
    var timelineEditActions: EditMenuActions? {
        get { self[TimelineEditKey.self] }
        set { self[TimelineEditKey.self] = newValue }
    }
}

/// The Edit menu's Cut, Copy, Paste, Duplicate, Delete and Select All, for
/// text and for the editor alike.
///
/// Text being typed in has them first, as everywhere on the Mac. Then
/// Beat Match while it is open, then the effects panel, then the timeline,
/// each command going to the first that offers it: with an effect selected
/// Copy copies the effect, and with only a clip selected the clip.
///
/// The panels' own key handling (`KeyPressMonitor`) still sees the keys
/// first and claims those it has always handled; what it leaves arrives
/// here.
struct EditCommands: Commands {
    @FocusedValue(\.beatMatchEditActions) private var beatMatch
    @FocusedValue(\.effectsEditActions) private var effects
    @FocusedValue(\.timelineEditActions) private var timeline

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            command("Cut", key: "x", text: #selector(NSText.cut(_:)), \.cut)
            command("Copy", key: "c", text: #selector(NSText.copy(_:)), \.copy)
            command("Paste", key: "v", text: #selector(NSText.paste(_:)), \.paste)
            Button("Duplicate") { editorAction(\.duplicate)?() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(editorAction(\.duplicate) == nil)
            Button("Delete") {
                if !sendToText(#selector(NSText.delete(_:))) { perform(editorAction(\.delete)) }
            }
            Divider()
            Button("Select All") { _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                .keyboardShortcut("a", modifiers: .command)
        }
    }

    private func command(_ name: String, key: KeyEquivalent, text selector: Selector, _ pick: KeyPath<EditMenuActions, (() -> Void)?>) -> some View {
        Button(name) {
            if !sendToText(selector) { perform(editorAction(pick), orSend: selector) }
        }
        .keyboardShortcut(key, modifiers: .command)
    }

    /// The first part of the editor's command, in order.
    private func editorAction(_ pick: KeyPath<EditMenuActions, (() -> Void)?>) -> (() -> Void)? {
        for actions in [beatMatch, effects, timeline] {
            if let action = actions?[keyPath: pick] { return action }
        }
        return nil
    }

    /// Sends `selector` to text being typed in; false when none is.
    private func sendToText(_ selector: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSText else { return false }
        return NSApp.sendAction(selector, to: nil, from: nil)
    }

    /// Runs `action`, or else offers `selector` to whatever has the
    /// keyboard (a list that copies its rows, say), or else beeps, as an
    /// Edit command with nothing to act on does.
    private func perform(_ action: (() -> Void)?, orSend selector: Selector? = nil) {
        if let action { return action() }
        if let selector, NSApp.sendAction(selector, to: nil, from: nil) { return }
        NSSound.beep()
    }
}
