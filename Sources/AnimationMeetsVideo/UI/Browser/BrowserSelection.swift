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
    /// The range each item had when the selection last moved off it, to
    /// pick again when it comes back (a plain click on it, or stepping to
    /// it). Dropping a range on purpose, by clicking its item outside it,
    /// forgets it. Items no longer listed keep theirs, unused, until
    /// `forgetRanges` drops them, so a listing that changes for a moment
    /// (scenes being found again) doesn't lose them. See docs/browser.md,
    /// "Selecting".
    private(set) var remembered: [ID: Range] = [:]
    /// Goes up each time the person picks something (clicks, Shift- and
    /// Command-clicks, ranges, clearing); dropping items that are gone
    /// doesn't count. What follows the selection, as the scene splitter
    /// does, watches this, so an edit that renames a scene doesn't move it.
    private(set) var revision = 0

    func contains(_ id: ID) -> Bool { items.contains(id) }

    /// A plain click on `id`, at `seconds` into it when known: selects the
    /// whole item, unless the click is inside the item's range, which stays.
    /// Coming back to an item that had a range when it was left picks that
    /// range again, unless `restoring` is off (a drag that carries the
    /// whole item, a list that shows no ranges).
    mutating func click(_ id: ID, at seconds: Double? = nil, restoring: Bool = true) {
        if let range, range.item == id {
            if let seconds, range.contains(seconds) { return }
            // Its own range dropped on purpose: not to come back.
            remembered[id] = nil
            self.range = nil
        } else {
            leaveRange()
            range = restoring ? remembered[id] : nil
        }
        revision += 1
        items = [id]
        anchor = id
    }

    /// Keeps the range picked, if any, as its item's to come back to.
    private mutating func leaveRange() {
        if let range { remembered[range.item] = range }
        range = nil
    }

    /// Command-click: adds the item, or takes it out if it was in.
    mutating func commandClick(_ id: ID) {
        revision += 1
        leaveRange()
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
        leaveRange()
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
        if range?.item != id { leaveRange() }
        remembered[id] = nil
        items = [id]
        anchor = id
        range = Range(item: id, start: start, end: end)
    }

    /// Command-A: every item listed, whole. The anchor stays when it is
    /// listed, so Shift-click still extends from it.
    mutating func selectAll(in order: [ID]) {
        revision += 1
        items = Set(order)
        leaveRange()
        if anchor.map(order.contains) != true { anchor = order.first }
    }

    mutating func clear() {
        revision += 1
        items = []
        anchor = nil
        leaveRange()
    }

    /// Drops items that are gone, keeping the order of what remains.
    mutating func keep(only order: [ID]) {
        let listed = Set(order)
        items.formIntersection(listed)
        if let anchor, !listed.contains(anchor) { self.anchor = nil }
        // Kept for when it is listed again, until `forgetRanges` says it's gone.
        if let range, !listed.contains(range.item) { leaveRange() }
    }

    /// Every item's range: the one picked now and those remembered, as
    /// spans, for keeping where the browser was left (`ViewState.Browser`).
    var rangeSpans: [ID: SecondsSpan] {
        var spans = remembered.mapValues { SecondsSpan(start: $0.start, end: $0.end) }
        if let range { spans[range.item] = SecondsSpan(start: range.start, end: range.end) }
        return spans
    }

    /// Takes up ranges kept from before (the browser opened again, or the
    /// project), to pick again as their items are come back to. The range
    /// picked now stays.
    mutating func remember(_ spans: [ID: SecondsSpan]) {
        remembered = Dictionary(uniqueKeysWithValues: spans.compactMap { id, span in
            span.end > span.start ? (id, Range(item: id, start: span.start, end: span.end)) : nil
        })
        if let range { remembered[range.item] = nil }
    }

    /// Drops the remembered ranges of items `gone` says are gone for good.
    mutating func forgetRanges(where gone: (ID) -> Bool) {
        remembered = remembered.filter { !gone($0.key) }
    }

    /// Holds remembered ranges to items' lengths now, given by `duration`
    /// (nil for an item not listed, whose range is left as it is), and
    /// drops one with nothing left of it.
    mutating func fitRanges(to duration: (ID) -> Double?) {
        remembered = remembered.compactMapValues { kept in
            guard let length = duration(kept.item) else { return kept }
            var fitted = kept
            fitted.start = kept.start.clamped(between: 0, and: length)
            fitted.end = kept.end.clamped(between: 0, and: length)
            return fitted.end > fitted.start ? fitted : nil
        }
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
    mutating func step(_ by: Int, from cursor: ID?, extending: Bool, in order: [ID], restoring: Bool = true) -> ID? {
        guard !order.isEmpty else { return nil }
        let from = cursor.flatMap(order.firstIndex(of:)) ?? (by > 0 ? -1 : order.count)
        let to = order[(from + by).clamped(between: 0, and: order.count - 1)]
        if extending {
            shiftClick(to, in: order)
        } else {
            click(to, restoring: restoring)
        }
        return to
    }
}
