import Foundation
import Testing

/// Waiting for work a test started but doesn't run itself: analysis,
/// decoding, rendering, a session loading its sound.
///
/// That work runs at utility priority, which the system holds back for as
/// long as other work keeps every core busy. With the whole suite running
/// in parallel on CI, a read that takes milliseconds alone has waited over
/// a minute, so waits that gave up after a few seconds failed with nothing
/// wrong. These waits go by what the test waits for, not by the clock:
/// `limit` is there only to end a wait for something that never comes.
enum Waiting {
    /// Twice the longest hold-up seen on CI (over a minute), and about as
    /// long as the whole suite takes there, after which nothing is left to
    /// crowd the work out. Kept short because CI is paid by the minute: a
    /// test that really broke a wait costs this much runner time.
    static let limit: Duration = .seconds(120)

    /// Thrown, after recording an issue, when a wait reaches its limit.
    struct TimedOut: Error, CustomStringConvertible {
        let what: String
        var description: String { "Timed out waiting: \(what)" }
    }
}

/// Waits until `condition` holds, checking it every `interval` on the
/// caller's actor. If it still doesn't after `limit`, records an issue
/// naming `what` and throws `Waiting.TimedOut`, so the test stops there
/// instead of checking state that never arrived.
func waitUntil(
    _ what: String,
    limit: Duration = Waiting.limit,
    every interval: Duration = .milliseconds(5),
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while try !condition() {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting: \(what)", sourceLocation: sourceLocation)
            throw Waiting.TimedOut(what: what)
        }
        try await Task.sleep(for: interval)
    }
}

/// Asks `produce` for a value every `interval` until it gives one, and
/// returns it; for something only an async call can tell. Times out like
/// `waitUntil`.
func waitFor<Value>(
    _ what: String,
    limit: Duration = Waiting.limit,
    every interval: Duration = .milliseconds(5),
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ produce: () async throws -> Value?
) async throws -> Value {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while true {
        if let value = try await produce() { return value }
        guard clock.now < deadline else {
            Issue.record("Timed out waiting: \(what)", sourceLocation: sourceLocation)
            throw Waiting.TimedOut(what: what)
        }
        try await Task.sleep(for: interval)
    }
}
