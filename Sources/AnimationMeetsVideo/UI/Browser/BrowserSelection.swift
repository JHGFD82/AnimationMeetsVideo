import Foundation

/// What is picked in a browser tab: whole items, or a range of one. Items
/// are identified by `ID`; their order is the browser's, passed in, so
/// Shift-click and drags follow what is on screen. See docs/browser.md,
/// "Selecting" and "Dragging".
struct BrowserSelection<ID: Hashable>: Equatable {
    /// Part of one item, in seconds into it.
    struct Range: Equatable {
        var item: ID
        var start: Double
        var end: Double

        func contains(_ seconds: Double) -> Bool { seconds >= start && seconds <= end }
    }

    private(set) var items: Set<ID> = []
    /// The item Shift-click extends from: the last one clicked.
    private(set) var anchor: ID?
    private(set) var range: Range?
    /// Goes up each time the person picks something (clicks, Shift- and
    /// Command-clicks, ranges, clearing); dropping items that are gone
    /// doesn't count. What follows the selection, as the scene splitter
    /// does, watches this, so an edit that renames a scene doesn't move it.
    private(set) var revision = 0

    func contains(_ id: ID) -> Bool { items.contains(id) }

    /// A plain click on `id`, at `seconds` into it when known: selects the
    /// whole item, unless the click is inside the item's range, which stays.
    mutating func click(_ id: ID, at seconds: Double? = nil) {
        if let range, range.item == id, let seconds, range.contains(seconds) { return }
        revision += 1
        items = [id]
        anchor = id
        range = nil
    }

    /// Command-click: adds the item, or takes it out if it was in.
    mutating func commandClick(_ id: ID) {
        revision += 1
        range = nil
        if items.contains(id) { items.remove(id) } else { items.insert(id) }
        anchor = id
    }

    /// Shift-click: every item from the anchor to `id`, in browser order.
    /// Without an anchor (or one no longer listed) it is a plain click.
    mutating func shiftClick(_ id: ID, in order: [ID]) {
        guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
            click(id)
            return
        }
        revision += 1
        range = nil
        items = Set(order[min(from, to)...max(from, to)])
    }

    /// Picks part of one item, from Option-drag or its handles; the ends may
    /// come in either order. Anything else picked is dropped.
    mutating func setRange(of id: ID, from a: Double, to b: Double, duration: Double) {
        let start = min(a, b).clamped(between: 0, and: duration), end = max(a, b).clamped(between: 0, and: duration)
        revision += 1
        items = [id]
        anchor = id
        range = Range(item: id, start: start, end: end)
    }

    mutating func clear() {
        revision += 1
        items = []
        anchor = nil
        range = nil
    }

    /// Drops items that are gone, keeping the order of what remains.
    mutating func keep(only order: [ID]) {
        let listed = Set(order)
        items.formIntersection(listed)
        if let anchor, !listed.contains(anchor) { self.anchor = nil }
        if let range, !listed.contains(range.item) { self.range = nil }
    }

    /// The selected items in browser order.
    func ordered(in order: [ID]) -> [ID] {
        order.filter(items.contains)
    }

    /// What a drag starting on `id` carries: every selected item in browser
    /// order when `id` is one of them, otherwise just `id`.
    func dragged(from id: ID, in order: [ID]) -> [ID] {
        items.contains(id) ? ordered(in: order) : [id]
    }
}
