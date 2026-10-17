import Foundation
import Observation

/// What is selected in the effects panel, shared with the timeline so the
/// Delete key goes to the panel while it has something selected.
@MainActor @Observable
final class EffectsPanelState {
    /// The effect selected, or the effect the selected control is in.
    var selectedEffectID: UUID?
    var selectedControlID: UUID?
    /// Effects folded up in the stack; the rest show their controls.
    var collapsed: Set<UUID> = []

    /// Show Up to Here: the clip and effect the viewer shows the clip
    /// after, with later effects and its transitions skipped.
    struct ShowUpTo: Equatable {
        var clipID: UUID
        var effectID: UUID
    }

    var showUpTo: ShowUpTo?

    var hasSelection: Bool { selectedEffectID != nil }

    func select(effect: UUID?, control: UUID? = nil) {
        selectedEffectID = effect
        selectedControlID = control
    }

    func clear() {
        select(effect: nil)
    }

    func isCollapsed(_ id: UUID) -> Bool { collapsed.contains(id) }

    func toggleCollapsed(_ id: UUID) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}
