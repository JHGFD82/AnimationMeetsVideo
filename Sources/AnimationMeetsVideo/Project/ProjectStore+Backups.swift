import CoreMedia
import Foundation

extension ProjectStore {
    static let backupPrefix = "autosave-"

    /// Writes a timestamped copy of the project into `Backups/` and deletes
    /// the oldest beyond `limit`. It never touches `project.json`, so an
    /// autosave can't overwrite work the person chose to save. To recover,
    /// copy a backup over `project.json`.
    @discardableResult
    static func writeBackup(
        of project: EditingProject,
        in packageURL: URL,
        now: Date = Date(),
        keeping limit: Int = 20
    ) throws -> URL {
        let folder = packageURL.appending(path: backupsFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = folder.appending(path: "\(backupPrefix)\(formatter.string(from: now)).json")
        try encode(project, packageURL: packageURL).write(to: url, options: .atomic)

        let backups = (try FileManager.default.contentsOfDirectory(atPath: folder.path))
            .filter { $0.hasPrefix(backupPrefix) && $0.hasSuffix(".json") }
            .sorted()
        for name in backups.dropLast(max(limit, 1)) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
        return url
    }

    /// The newest autosave, when it was written after `project.json` and
    /// holds something different: work that was never saved, as when the
    /// app quit without saving or crashed.
    static func unsavedBackup(in packageURL: URL) -> URL? {
        let folder = packageURL.appending(path: backupsFolderName, directoryHint: .isDirectory)
        let projectURL = packageURL.appending(path: projectFileName)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              let newest = names.filter({ $0.hasPrefix(backupPrefix) && $0.hasSuffix(".json") }).sorted().last,
              let saved = modificationDate(of: projectURL)
        else {
            return nil
        }
        let backup = folder.appending(path: newest)
        guard let written = modificationDate(of: backup), written > saved,
              (try? Data(contentsOf: backup)) != (try? Data(contentsOf: projectURL))
        else {
            return nil
        }
        return backup
    }

    /// Marks every autosave as older than `project.json`, once the person
    /// has chosen not to keep what they hold, so they aren't offered again.
    /// The backups themselves are kept.
    static func markBackupsSeen(in packageURL: URL) {
        let folder = packageURL.appending(path: backupsFolderName, directoryHint: .isDirectory)
        guard let saved = modificationDate(of: packageURL.appending(path: projectFileName)),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else {
            return
        }
        for name in names where name.hasPrefix(backupPrefix) {
            let url = folder.appending(path: name)
            // A second earlier, since dates round on disk and an exact copy
            // could still read as newer.
            if let written = modificationDate(of: url), written > saved {
                try? FileManager.default.setAttributes([.modificationDate: saved.addingTimeInterval(-1)], ofItemAtPath: url.path)
            }
        }
    }

    /// `markBackupsSeen`, in turn with everything else that changes the package.
    static func markBackupsSeenQueued(in packageURL: URL) async {
        _ = try? await PackageCoordinator.shared.run(on: [packageURL]) { markBackupsSeen(in: packageURL) }
    }

    /// Moves an existing package to the Trash, after anything already queued
    /// on it. With `checkingLock`, a package another window or app has open
    /// is refused (the lock is released again at once).
    static func trashPackage(at url: URL, checkingLock: Bool) async throws {
        try await PackageCoordinator.shared.run(on: [url]) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            if checkingLock, (try? validatePackage(at: url)) != nil {
                _ = try ProjectLock.acquire(at: url)
            }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try? fresh.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
