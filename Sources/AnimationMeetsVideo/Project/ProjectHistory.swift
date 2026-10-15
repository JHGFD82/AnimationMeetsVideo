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
    /// Where saves moved each asset's file, in order. Undo snapshots taken
    /// before a move still hold the old place; restoring one applies these.
    private var mediaMoves: [UUID: [MediaMove]] = [:]

    private struct MediaMove {
        var from: URL
        var to: URL
        var stamp: FileStamp?
    }

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
        mediaMoves = [:]
        undoManager?.removeAllActions()
    }

    /// Applies a change to the baseline so it is not recorded as an edit,
    /// such as media URLs being rewritten by a save. Apply the same change to
    /// the live project.
    func adopt(_ change: (inout EditingProject) -> Void) {
        change(&baseline)
    }

    /// Takes on the file locations a save gave the assets of `original` in
    /// `saved`, without recording an edit. Undo and redo apply them too, so
    /// stepping back past Save As doesn't point assets at the files' old
    /// places, which may be in the package the project was saved from.
    /// Apply the same locations to the live project.
    func adoptMediaLocations(of original: EditingProject, from saved: EditingProject) {
        baseline.applyMediaLocations(from: saved)
        for clip in original.clips {
            guard let from = clip.url, let moved = saved.mediaClip(id: clip.id), let to = moved.url, to != from else { continue }
            mediaMoves[clip.id, default: []].append(MediaMove(from: from, to: to, stamp: moved.acceptedStamp))
        }
    }

    /// `snapshot` with every asset at the place saves have moved its file to.
    private func relocated(_ snapshot: EditingProject) -> EditingProject {
        guard !mediaMoves.isEmpty else { return snapshot }
        var project = snapshot
        for index in project.clips.indices {
            for move in mediaMoves[project.clips[index].id] ?? [] where project.clips[index].url == move.from {
                project.clips[index].url = move.to
                project.clips[index].acceptedStamp = move.stamp
            }
        }
        return project
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
        let snapshot = relocated(snapshot)
        let current = baseline
        baseline = snapshot
        lastRecordedAt = nil
        restore?(snapshot)
        // Registered while undoing this becomes the redo step, and vice versa.
        registerUndo(restoring: current)
    }
}
