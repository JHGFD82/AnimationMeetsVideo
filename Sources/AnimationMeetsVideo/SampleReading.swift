import Foundation

/// Runs blocking media reads away from Swift's cooperative thread pool.
///
/// `AVAssetReaderOutput.copyNextSampleBuffer()` blocks its thread until
/// the next sample is decoded. The cooperative pool has only as many
/// threads as there are cores, so a few such reads at once can occupy all
/// of them and stall every other task in the process, sometimes for good.
/// The reads run on a dispatch queue of their own instead.
enum SampleReading {
    private static let queue = DispatchQueue(
        label: "AnimationMeetsVideo.sample-reading", qos: .utility, attributes: .concurrent
    )

    /// Runs `body` on the reading queue and returns its result. `body` gets
    /// a check that turns true once the calling task is cancelled, since
    /// `Task.isCancelled` means nothing on a dispatch thread; it should
    /// stop reading and throw `CancellationError` then.
    static func run<T: Sendable>(
        _ body: @escaping @Sendable (_ isCancelled: @Sendable () -> Bool) throws -> T
    ) async throws -> T {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try body { flag.isSet } })
                }
            }
        } onCancel: {
            flag.set()
        }
    }
}

private final class CancellationFlag: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}

/// Hands a value that isn't `Sendable`, such as an `AVAssetTrack`, to the
/// reading queue. Only for values that the sender stops using once handed
/// over, so that one thread touches them at a time.
struct HandedOver<Value>: @unchecked Sendable {
    let value: Value
}
