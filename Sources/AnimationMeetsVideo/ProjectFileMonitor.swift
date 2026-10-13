import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// Notices when `project.json` was changed by something other than this app.
///
/// The app records what the file looked like each time it reads or writes it,
/// so its own saves never count as changes. A cheap size-and-date check runs
/// first; the contents are hashed only when that differs, so touching the
/// file without editing it is ignored.
@MainActor
final class ProjectFileMonitor {
    struct Change: Equatable {
        fileprivate var stamp: FileStamp?
        fileprivate var digest: Data
    }

    private var fileURL: URL?
    private var knownStamp: FileStamp?
    private var knownDigest: Data?

    /// Starts watching a package, taking its file as it is now as the baseline.
    func track(package url: URL) {
        let file = url.appending(path: ProjectStore.projectFileName)
        fileURL = file
        knownStamp = FileStamp(url: file)
        knownDigest = (try? Data(contentsOf: file)).map(Self.digest)
    }

    func stop() {
        fileURL = nil
        knownStamp = nil
        knownDigest = nil
    }

    /// The change since the baseline, if the file's contents differ. A file
    /// that is missing or unreadable is not a change; saving writes it again.
    func pendingChange() -> Change? {
        guard let fileURL, let stamp = FileStamp(url: fileURL), stamp != knownStamp else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let digest = Self.digest(data)
        if digest == knownDigest {
            knownStamp = stamp
            return nil
        }
        return Change(stamp: stamp, digest: digest)
    }

    /// Takes the change as the new baseline, whether it was loaded or
    /// deliberately kept out, so it isn't reported again.
    func acknowledge(_ change: Change) {
        knownStamp = change.stamp
        knownDigest = change.digest
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

extension View {
    /// Calls `check` every couple of seconds and whenever the app becomes active.
    func onExternalProjectChange(perform check: @escaping @MainActor () -> Void) -> some View {
        onPeriodicCheck(every: .seconds(2), perform: check)
    }

    /// Calls `check` every `interval` while the view is shown, and whenever
    /// the app becomes active, since files are most likely to have been
    /// changed while it was in the background.
    func onPeriodicCheck(every interval: Duration, perform check: @escaping @MainActor () async -> Void) -> some View {
        self
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    await check()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await check() }
            }
    }
}
