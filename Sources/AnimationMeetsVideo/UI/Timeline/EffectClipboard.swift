import Foundation
import Observation

/// The effects copied last, shared by every project and window of the app.
@MainActor @Observable
final class EffectClipboard {
    static let shared = EffectClipboard()

    var bundle: EffectBundle?

    var isEmpty: Bool { bundle == nil }
}
