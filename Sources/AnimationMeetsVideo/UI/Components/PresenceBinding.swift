extension Optional {
    /// Whether there is a value; setting it false clears the value. Bound
    /// as `$error.isPresent`, it presents an alert or dialog while there is
    /// one, and dismissing it clears it.
    var isPresent: Bool {
        get { self != nil }
        set { if !newValue { self = nil } }
    }
}
