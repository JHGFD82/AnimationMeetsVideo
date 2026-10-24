extension Comparable {
    /// The value, or the nearer bound when it falls outside them.
    ///
    /// The bounds are two values rather than a range, so they may cross
    /// without trapping, as a range's would: then the result is `high`,
    /// as `min(max(x, low), high)` gives.
    func clamped(between low: Self, and high: Self) -> Self {
        min(max(self, low), high)
    }
}
