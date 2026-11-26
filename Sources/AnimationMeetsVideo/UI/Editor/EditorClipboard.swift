import AppKit
import Foundation
import Observation

/// What was copied last, shared by every project and window of the app:
/// effects, or a clip. As with the system's clipboard, Paste pastes what
/// was copied last. A copied clip brings its effects, time and shutter too,
/// so Paste Effects can add its stack to another clip and take over its time
/// and shutter.
@MainActor @Observable
final class EditorClipboard {
    static let shared = EditorClipboard()

    /// The effects copied last, or the copied clip's.
    private(set) var effects: EffectBundle?
    /// The clip copied last, unless effects were copied after it.
    private(set) var clip: ClipBundle?
    /// The clips copied together last (`ClipGroupBundle`), unless something
    /// was copied after them.
    private(set) var group: ClipGroupBundle?
    /// The keyframes copied last from the effects panel's lanes, unless
    /// something was copied after them (docs/parameter-rows.md).
    private(set) var keyframes: CopiedKeyframes?

    var hasEffects: Bool { effects != nil }

    /// Whether Paste Effects has something to put on a clip: effects, or a
    /// copied clip whose time and shutter come along with its effects.
    var canPasteEffects: Bool { effects != nil || clip != nil }

    func copy(effects: EffectBundle?) {
        self.effects = effects
        clip = nil
        group = nil
        keyframes = nil
    }

    /// Keyframes, also put on the pasteboard as text, which pastes into a
    /// text editor.
    func copy(keyframes: CopiedKeyframes) {
        self.keyframes = keyframes
        effects = nil
        clip = nil
        group = nil
        if let json = keyframes.json {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(json, forType: .string)
        }
    }

    func copy(clip: ClipBundle, effects: EffectBundle?) {
        self.clip = clip
        self.effects = effects
        group = nil
        keyframes = nil
    }

    /// Several clips at once. They have no one stack of effects to paste.
    func copy(group: ClipGroupBundle) {
        self.group = group
        clip = nil
        effects = nil
        keyframes = nil
    }

    /// Whether something that pastes as clips is on the clipboard.
    var hasClips: Bool { clip != nil || group != nil }
}
