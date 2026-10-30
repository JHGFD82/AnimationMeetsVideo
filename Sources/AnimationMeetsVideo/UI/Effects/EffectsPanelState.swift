import Foundation
import Observation

/// What is selected in the effects panel, shared with the timeline so the
/// Delete key goes to the panel while it has something selected.
@MainActor @Observable
final class EffectsPanelState {
    /// The effect selected, or the effect the selected control is in: the
    /// one last clicked when several rows are picked.
    var selectedEffectID: UUID?
    var selectedControlID: UUID?
    /// The effects and controls picked, by ID: the one selected, or several
    /// Command- or Shift-clicked (see `SelectClick`).
    private(set) var pickedRows = SelectionSet<UUID>()
    /// The keyframes picked in the lanes.
    let keyframes = LaneKeyframePicks()
    /// Effects folded up in the stack; the rest show their controls.
    var collapsed: Set<UUID> = []

    /// Show Up to Here: the clip and effect the viewer shows the clip
    /// after, with later effects and its transitions skipped.
    struct ShowUpTo: Equatable {
        var clipID: UUID
        var effectID: UUID
    }

    var showUpTo: ShowUpTo?

    var hasSelection: Bool { selectedEffectID != nil || !keyframes.isEmpty }

    /// Whether more than one effect or control is picked.
    var picksSeveralRows: Bool { pickedRows.count > 1 }

    func isPicked(_ id: UUID) -> Bool { pickedRows.contains(id) }

    func select(effect: UUID?, control: UUID? = nil) {
        selectedEffectID = effect
        selectedControlID = control
        let id = control ?? effect
        pickedRows.set(id.map { [$0] } ?? [], anchor: id)
    }

    /// A click on an effect's row, or a control's: picks it alone, or with
    /// Command adds it or takes it out, or with Shift picks the rows from
    /// the one last clicked, in `order` (the stack's, top to bottom).
    func click(effect: UUID, control: UUID? = nil, in order: [UUID], as click: SelectClick = .current) {
        guard click != .only else { return select(effect: effect, control: control) }
        let id = control ?? effect
        pickedRows.click(id, click, in: order)
        if pickedRows.isEmpty {
            clear()
        } else if pickedRows.contains(id) {
            selectedEffectID = effect
            selectedControlID = control
        }
    }

    func clear() {
        select(effect: nil)
    }

    func isCollapsed(_ id: UUID) -> Bool { collapsed.contains(id) }

    func toggleCollapsed(_ id: UUID) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}
