extension Collection where Element: Identifiable {
    /// Where the element with this ID is, if any is.
    func firstIndex(id: Element.ID) -> Index? {
        firstIndex { $0.id == id }
    }

    /// The element with this ID, if any is.
    func first(id: Element.ID) -> Element? {
        first { $0.id == id }
    }
}

extension Array {
    /// Inserts `element` at `index`, or at the nearer end when `index`
    /// falls outside the array.
    mutating func insert(_ element: Element, clampedAt index: Int) {
        insert(element, at: index.clamped(between: 0, and: count))
    }
}
