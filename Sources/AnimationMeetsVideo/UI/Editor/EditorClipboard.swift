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

    var hasEffects: Bool { effects != nil }

    func copy(effects: EffectBundle?) {
        self.effects = effects
        clip = nil
    }

    func copy(clip: ClipBundle, effects: EffectBundle?) {
        self.clip = clip
        self.effects = effects
    }
}
