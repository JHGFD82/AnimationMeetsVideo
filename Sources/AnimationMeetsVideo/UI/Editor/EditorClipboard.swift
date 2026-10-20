import Foundation
import Observation

/// What was copied last, shared by every project and window of the app:
/// effects, or a clip. As with the system's clipboard, Paste pastes what
/// was copied last. A copied clip brings its effects too, so Paste Effects
/// can put its whole stack on another clip.
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

    var hasEffects: Bool { effects != nil }

    func copy(effects: EffectBundle?) {
        self.effects = effects
        clip = nil
        group = nil
    }

    func copy(clip: ClipBundle, effects: EffectBundle?) {
        self.clip = clip
        self.effects = effects
        group = nil
    }

    /// Several clips at once. They have no one stack of effects to paste.
    func copy(group: ClipGroupBundle) {
        self.group = group
        clip = nil
        effects = nil
    }

    /// Whether something that pastes as clips is on the clipboard.
    var hasClips: Bool { clip != nil || group != nil }
}
