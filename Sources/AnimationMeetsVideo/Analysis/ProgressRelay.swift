import Foundation

/// Carries progress from a worker thread to the main actor with at most one
/// update waiting, so a fast reporter can't pile up main-actor tasks. The
/// latest value wins; values that aren't numbers are ignored.
final class ProgressRelay: @unchecked Sendable {
    private let state = NSLock()
    private var latest: Double?
    private var scheduled = false
    private let deliver: @MainActor @Sendable (Double) -> Void

    init(deliver: @escaping @MainActor @Sendable (Double) -> Void) {
        self.deliver = deliver
    }

    var report: @Sendable (Double) -> Void {
        { [self] fraction in
            guard fraction.isFinite else { return }
            let needsTask = state.withLock { () -> Bool in
                latest = fraction
                defer { scheduled = true }
                return !scheduled
            }
            guard needsTask else { return }
            Task { @MainActor in
                let value = state.withLock { () -> Double? in
                    defer { latest = nil; scheduled = false }
                    return latest
                }
                if let value { deliver(value) }
            }
        }
    }
}
