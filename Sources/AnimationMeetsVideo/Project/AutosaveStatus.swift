import Foundation
import Observation

/// Whether the automatic backups of the open project are being written.
/// A failed backup used to go only to the log, so someone counting on
/// recovery after a crash had no way to know it had stopped; the toolbar
/// shows this while it is failing (`AutosaveWarning`).
@MainActor
@Observable
final class AutosaveStatus {
    /// Why the latest backup couldn't be written, while backups fail.
    private(set) var failure: String?
    /// When backups started failing, kept across repeated failures.
    private(set) var failingSince: Date?
    /// Saves the project, for the warning's Save Now.
    @ObservationIgnored var save: (() -> Void)?

    func failed(_ reason: String, at date: Date = Date()) {
        failure = reason
        if failingSince == nil { failingSince = date }
    }

    /// A backup or a save was written: nothing is at risk any more.
    func succeeded() {
        guard failure != nil else { return }
        failure = nil
        failingSince = nil
    }
}
