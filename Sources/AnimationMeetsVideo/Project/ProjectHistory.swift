import Foundation

/// Undo and redo for the project, built on the window's `UndoManager` so the
/// Edit menu and Cmd+Z work natively.
///
/// Edits are detected by comparing the project to a baseline rather than at
/// each call site, so every change is undoable, including ones added later.
/// Each step is named for the Edit menu by `ProjectChange` (what was done
/// to which clip). Changes in quick succession merge into one undo step
/// only when they are the same edit to the same things (stepping one
/// control with the arrow keys), told by the step's hidden identity.
@MainActor
final class ProjectHistory {
    static let coalescingInterval: TimeInterval = 0.5

    private(set) var baseline: EditingProject
    private var lastRecordedAt: Date?
    /// The identity of the last step recorded, which a quick change
    /// merges into only when it is the same edit to the same things.
    private var lastRecordedIdentity: Int?
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
    /// Reads the app's project state as it is now.
    var current: (() -> EditingProject)?

    init(project: EditingProject) {
        baseline = project
    }

    /// Starts a fresh history for a newly created or opened project.
    func reset(to project: EditingProject) {
        baseline = project
        lastRecordedAt = nil
        lastRecordedIdentity = nil
        mediaMoves = [:]
        undoManager?.removeAllActions()
    }

    /// Applies a change to the baseline so it is not recorded as an edit,
    /// such as media URLs being rewritten by a save. Apply the same change to
    /// the live project.
    func adopt(_ change: (inout EditingProject) -> Void) {
        change(&baseline)
    }

    /// Whether a gesture holds the changes back (see `beginGesture`).
    private(set) var isInGesture = false
    /// Whether the gesture under way told the viewer it began.
    private var gestureNotified = false

    /// Starts a gesture, such as dragging a value, whose changes are one
    /// step however long it takes: they aren't recorded until `endGesture`,
    /// so the project can be put back as it was in the meantime (Escape)
    /// without leaving a step behind. Unless `quietly`, the viewer is told,
    /// and holds back swapping its player until the gesture ends; a
    /// session of edits the viewer should follow as they are made (the
    /// motion designer's) is quiet.
    func beginGesture(quietly: Bool = false) {
        isInGesture = true
        gestureNotified = !quietly
        if !quietly { NotificationCenter.default.post(name: .valueGestureDidBegin, object: self) }
    }

    /// Records the gesture's changes, if there were any, as one step.
    /// `project` is the project as it is now, by default read from `current`.
    func endGesture(_ project: EditingProject? = nil) {
        guard isInGesture else { return }
        isInGesture = false
        lastRecordedAt = nil
        lastRecordedIdentity = nil
        if let project = project ?? current?() { projectDidChange(project) }
        if gestureNotified { NotificationCenter.default.post(name: .valueGestureDidEnd, object: self) }
        gestureNotified = false
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
        guard !isInGesture else { return }
        guard project != baseline else { return }
        let before = baseline
        baseline = project
        let step = ProjectChange.step(from: before, to: project)

        if let last = lastRecordedAt,
           now.timeIntervalSince(last) < Self.coalescingInterval,
           step?.identity == lastRecordedIdentity,
           undoManager?.canUndo == true {
            lastRecordedAt = now
            return
        }
        lastRecordedAt = now
        lastRecordedIdentity = step?.identity
        registerUndo(restoring: before, name: step?.name)
    }

    private func registerUndo(restoring snapshot: EditingProject, name: String?) {
        undoManager?.registerUndo(withTarget: self) { history in
            MainActor.assumeIsolated { history.apply(snapshot, name: name) }
        }
        if let name { undoManager?.setActionName(name) }
    }

    private func apply(_ snapshot: EditingProject, name: String?) {
        let snapshot = relocated(snapshot)
        let current = baseline
        baseline = snapshot
        lastRecordedAt = nil
        lastRecordedIdentity = nil
        restore?(snapshot)
        // Registered while undoing this becomes the redo step, and vice
        // versa, under the same name.
        registerUndo(restoring: current, name: name)
    }
}

extension Notification.Name {
    /// A gesture of many small edits (dragging a value) began or ended. The
    /// viewer holds its picture while one is going and shows the result
    /// when it ends.
    static let valueGestureDidBegin = Notification.Name("valueGestureDidBegin")
    static let valueGestureDidEnd = Notification.Name("valueGestureDidEnd")
}
