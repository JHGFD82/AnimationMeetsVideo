import Foundation

/// Runs everything that changes a project package, one piece at a time per
/// package and in the order it was asked: saves, Save As, analysis results,
/// and the deletion of results that no longer apply. Without it two writers
/// can interleave on disk even when each file is written atomically: a save
/// can copy reference data while a result is half-way in, and a deletion can
/// finish before an older write of the same file and let it come back.
///
/// An operation that involves two packages, as Save As does, waits for
/// everything queued on both and holds both until it is done. Operations are
/// queued in the order `run` is called, which on the main actor is the order
/// the callers asked in.
actor PackageCoordinator {
    static let shared = PackageCoordinator()

    private var tails: [String: Task<Void, Never>] = [:]

    func run<T: Sendable>(
        on packages: [URL],
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let keys = Set(packages.map(Self.key)).sorted()
        let before = keys.compactMap { tails[$0] }
        let work = Task<Result<T, Error>, Never> {
            for earlier in before { await earlier.value }
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        let marker = Task<Void, Never> { _ = await work.value }
        for key in keys { tails[key] = marker }
        let result = await work.value
        for key in keys where tails[key] == marker { tails[key] = nil }
        return try result.get()
    }

    /// The same package reached by different paths shares one queue.
    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
