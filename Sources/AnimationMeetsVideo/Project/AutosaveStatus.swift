import Foundation
import Observation

/// Whether what the app writes on its own for the open project is being
/// written: its saves after every change and its backups. A failure used
/// to go only to the log, so someone counting on it had no way to know it
/// had stopped; the toolbar shows this while it is failing
/// (`AutosaveWarning`).
@MainActor
@Observable
final class AutosaveStatus {
    enum Kind {
        /// Saving after every change (`Preferences.savesAutomatically`).
        case save
        /// A backup: the package's own autosave or one in the backup folder.
        case backup
    }

    /// Why the latest write couldn't be made, while writes fail.
    private(set) var failure: String?
    /// What failed last.
    private(set) var kind = Kind.backup
    /// When writes started failing, kept across repeated failures.
    private(set) var failingSince: Date?
    /// Saves the project, for the warning's Save Now.
    @ObservationIgnored var save: (() -> Void)?

    func failed(_ reason: String, kind: Kind = .backup, at date: Date = Date()) {
        failure = reason
        self.kind = kind
        if failingSince == nil { failingSince = date }
    }

    /// A write succeeded: nothing is at risk any more. A save clears any
    /// failure, since the work is on disk; a backup clears only a backup's,
    /// so it can't hide that saves are failing.
    func succeeded(_ written: Kind = .save) {
        guard failure != nil, written == .save || kind == .backup else { return }
        failure = nil
        failingSince = nil
    }
}
