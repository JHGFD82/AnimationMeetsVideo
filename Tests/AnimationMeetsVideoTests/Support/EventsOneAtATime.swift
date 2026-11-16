import Testing

/// Runs each test of the suites it's on alone among them: one test at a
/// time across every suite using `EventHarness`, while the rest of the
/// tests still run in parallel.
///
/// `.serialized` only orders the tests inside one suite; Swift Testing
/// still runs suites side by side. Every event test is on the main actor
/// and waits between events (`EventHarness.settle`), so two suites' tests
/// would take turns there, each opening its own window, which takes the
/// key status and the events from the other's. Run one suite at a time
/// they always passed; run together, about half failed.
struct EventsOneAtATime: SuiteTrait, TestTrait, TestScoping {
    /// Reaches each test in the suite, which is what the lock is taken for.
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        // The suite itself, as distinct from its tests, runs nothing that
        // opens a window: only its tests wait for the lock.
        guard !test.isSuite else { return try await function() }
        try await EventTestLock.shared.run(function)
    }
}

extension Trait where Self == EventsOneAtATime {
    /// See `EventsOneAtATime`.
    static var eventsOneAtATime: Self { EventsOneAtATime() }
}

/// A first-come, first-served lock that async work waits on without
/// holding a thread.
private actor EventTestLock {
    static let shared = EventTestLock()

    private var isHeld = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run(_ body: @Sendable () async throws -> Void) async throws {
        await acquire()
        do {
            try await body()
        } catch {
            release()
            throw error
        }
        release()
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        // Handed the lock straight from `release`, so it stays held.
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            isHeld = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
