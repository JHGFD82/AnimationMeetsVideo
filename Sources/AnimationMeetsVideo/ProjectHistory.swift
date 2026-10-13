import Foundation

/// Undo and redo for the project, built on the window's `UndoManager` so the
/// Edit menu and Cmd+Z work natively.
///
/// Edits are detected by comparing the project to a baseline rather than at
/// each call site, so every change is undoable, including ones added later.
/// Changes that arrive in quick succession (dragging a slider) merge into one
/// undo step.
@MainActor
final class ProjectHistory {
    static let coalescingInterval: TimeInterval = 0.5

    private(set) var baseline: EditingProject
    private var lastRecordedAt: Date?

    var undoManager: UndoManager?
    /// Writes a restored snapshot back into the app's project state.
    var restore: ((EditingProject) -> Void)?

    init(project: EditingProject) {
        baseline = project
    }

    /// Starts a fresh history for a newly created or opened project.
    func reset(to project: EditingProject) {
        baseline = project
        lastRecordedAt = nil
        undoManager?.removeAllActions()
    }

    /// Applies a change to the baseline so it is not recorded as an edit,
    /// such as media URLs being rewritten by a save. Apply the same change to
    /// the live project.
    func adopt(_ change: (inout EditingProject) -> Void) {
        change(&baseline)
    }

    /// Call whenever the project value changes.
    func projectDidChange(_ project: EditingProject, now: Date = Date()) {
        guard project != baseline else { return }
        let before = baseline
        baseline = project

        if let last = lastRecordedAt,
           now.timeIntervalSince(last) < Self.coalescingInterval,
           undoManager?.canUndo == true {
            lastRecordedAt = now
            return
        }
        lastRecordedAt = now
        registerUndo(restoring: before)
    }

    private func registerUndo(restoring snapshot: EditingProject) {
        undoManager?.registerUndo(withTarget: self) { history in
            MainActor.assumeIsolated { history.apply(snapshot) }
        }
    }

    private func apply(_ snapshot: EditingProject) {
        let current = baseline
        baseline = snapshot
        lastRecordedAt = nil
        restore?(snapshot)
        // Registered while undoing this becomes the redo step, and vice versa.
        registerUndo(restoring: current)
    }
}
