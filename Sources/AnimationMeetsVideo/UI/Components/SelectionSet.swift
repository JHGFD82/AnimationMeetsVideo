import AppKit

/// What a click does to a selection, the same in every editor with several
/// things to pick (the timeline, the graph editor, the motion designer, the
/// effects panel): a plain click picks the one thing alone, Command adds it
/// or takes it out, Shift picks the run from the one last clicked to it.
/// Dragging in empty space draws a lasso, which Shift or Command add to.
enum SelectClick: Equatable {
    case only, toggle, extend

    init(_ flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            self = .toggle
        } else if flags.contains(.shift) {
            self = .extend
        } else {
            self = .only
        }
    }

    /// The click being handled now. A tap gesture is heard after the
    /// event that ended it has gone, so the keys held down count too.
    @MainActor static var current: SelectClick {
        SelectClick(NSEvent.modifierFlags.union(NSApp.currentEvent?.modifierFlags ?? []))
    }

    /// Whether a lasso begun with `flags` adds to what is picked rather
    /// than starting over.
    static func lassoAdds(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.isDisjoint(with: [.shift, .command])
    }
}

/// Several things picked in an editor, by `ID`, and the one last clicked,
/// which a Shift-click extends from. Their order is the editor's, passed
/// in, so a run follows what is on screen (keyframes by time, rows top to
/// bottom).
struct SelectionSet<ID: Hashable>: Equatable {
    private(set) var items: Set<ID> = []
    private(set) var anchor: ID?

    init(_ items: Set<ID> = [], anchor: ID? = nil) {
        self.items = items
        self.anchor = anchor ?? (items.count == 1 ? items.first : nil)
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    func contains(_ id: ID) -> Bool { items.contains(id) }

    /// The one thing picked, when there is exactly one.
    var single: ID? { items.count == 1 ? items.first : nil }

    /// A click on `id`, as `click` says (see `SelectClick`).
    mutating func click(_ id: ID, _ click: SelectClick, in order: [ID]) {
        switch click {
        case .only:
            items = [id]
            anchor = id
        case .toggle:
            if items.contains(id) { items.remove(id) } else { items.insert(id) }
            anchor = id
        case .extend:
            guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
                return self.click(id, .only, in: order)
            }
            items = Set(order[min(from, to)...max(from, to)])
        }
    }

    /// A press on `id` that may begin a drag: one not picked is picked
    /// alone (or added, with Shift or Command), so the drag moves it; one
    /// already picked keeps the rest, so the drag moves them all.
    mutating func press(_ id: ID, _ click: SelectClick) {
        guard !items.contains(id) else { return }
        if click == .only { items = [id] } else { items.insert(id) }
        anchor = id
    }

    /// What a lasso covers, added to `kept` (what was picked when it began,
    /// with Shift or Command held; else nothing).
    mutating func lasso(_ covered: Set<ID>, keeping kept: Set<ID>) {
        items = kept.union(covered)
        if items.count == 1 { anchor = items.first }
    }

    /// Picks exactly these, as a move or an edit leaves them; the anchor
    /// goes along when it moved.
    mutating func set(_ ids: Set<ID>, anchor: ID? = nil) {
        items = ids
        if let anchor { self.anchor = anchor } else if let current = self.anchor, !ids.contains(current) { self.anchor = ids.count == 1 ? ids.first : nil }
    }

    mutating func selectAll(_ ids: [ID]) {
        items = Set(ids)
    }

    mutating func clear() {
        items = []
        anchor = nil
    }

    /// Lets go of what is gone; the anchor too.
    mutating func keep(only present: Set<ID>) {
        guard !items.isSubset(of: present) || anchor.map({ !present.contains($0) }) == true else { return }
        items.formIntersection(present)
        if let anchor, !present.contains(anchor) { self.anchor = nil }
    }
}
