extension Comparable {
    /// The value, or the range's nearer bound when it falls outside.
    ///
    /// A range can't be made with its bounds out of order, so where they
    /// come from values that may cross, `min(max(x, low), high)` is still
    /// the way, giving `high` when they do.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
