import CoreGraphics
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

    /// Whether a plain press on `id`, at `seconds` into it, drags media
    /// once it moves: on an item selected whole, or inside its range. A
    /// press anywhere else picks a range of the item instead.
    func pressDrags(_ id: ID, at seconds: Double) -> Bool {
        if let range, range.item == id { return range.contains(seconds) }
        return items.contains(id)
    }

    /// Picks part of one item, from dragging across it or its handles; the ends may
    /// come in either order. Anything else picked is dropped.
    mutating func setRange(of id: ID, from a: Double, to b: Double, duration: Double) {
        let start = min(a, b).clamped(between: 0, and: duration), end = max(a, b).clamped(between: 0, and: duration)
        revision += 1
        items = [id]
        anchor = id
        range = Range(item: id, start: start, end: end)
    }

    /// Command-A: every item listed, whole. The anchor stays when it is
    /// listed, so Shift-click still extends from it.
    mutating func selectAll(in order: [ID]) {
        revision += 1
        items = Set(order)
        range = nil
        if anchor.map(order.contains) != true { anchor = order.first }
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

// What the Clips tab and the Timelines tab's filmstrips do alike with a
// selection: range handles, I and O, and the arrow keys.
extension BrowserSelection {
    enum RangeEnd { case start, end }

    /// How close to a range's end a press grabs its handle.
    static var handleReach: CGFloat { 6 }

    /// The end of `id`'s range whose handle is at `point` on its filmstrip:
    /// the far end, which stays put while the handle is dragged. Nil off
    /// the handles, or when `id` has no range.
    func handle(of id: ID, at point: CGPoint, in layout: FilmstripLayout) -> Double? {
        guard let range, range.item == id else { return nil }
        let start = layout.position(atSeconds: range.start), end = layout.position(atSeconds: range.end)
        let row = Int(point.y / layout.rowPitch)
        if row == start.row, abs(point.x - start.x) <= Self.handleReach { return range.end }
        if row == end.row, abs(point.x - end.x) <= Self.handleReach { return range.start }
        return nil
    }

    /// I or O: sets the start or end of `id`'s range at `seconds`, keeping
    /// its other end, or the item's own when it has no range yet.
    mutating func setRangeEnd(_ end: RangeEnd, of id: ID, at seconds: Double, duration: Double) {
        let current = range?.item == id ? range : nil
        switch end {
        case .start: setRange(of: id, from: seconds, to: max(current?.end ?? duration, seconds), duration: duration)
        case .end: setRange(of: id, from: min(current?.start ?? 0, seconds), to: seconds, duration: duration)
        }
    }

    /// Up or Down: selects the item `by` steps from `cursor` in `order`
    /// (from before the first, or after the last, without one), stopping at
    /// the ends; with `extending`, the run from the anchor to it, as
    /// Shift-click. Returns it, the new cursor; nil with nothing listed.
    @discardableResult
    mutating func step(_ by: Int, from cursor: ID?, extending: Bool, in order: [ID]) -> ID? {
        guard !order.isEmpty else { return nil }
        let from = cursor.flatMap(order.firstIndex(of:)) ?? (by > 0 ? -1 : order.count)
        let to = order[(from + by).clamped(between: 0, and: order.count - 1)]
        if extending {
            shiftClick(to, in: order)
        } else {
            click(to)
        }
        return to
    }
}
