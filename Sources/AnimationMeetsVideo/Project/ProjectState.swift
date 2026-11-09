import Foundation
import Observation

/// The project being edited, which the app's views read and write through
/// `value`, as a binding to it.
///
/// A value drag holds its steps to one side: what a step inside `hold`
/// writes goes to `held`, which only the viewer and the dragged field
/// follow, and the project takes the drag's last value once, when it ends.
/// Written to the project, every step ran the bodies of the whole editor
/// again, which read the project from its root down (about 17 ms a step
/// with the effects panel open); held, a step costs what the viewer does.
///
/// What follows a held drag, and what doesn't:
/// - The viewer, the sound and the graph windows follow (the editor's
///   surface reads `held` for them), since they are the point of dragging.
/// - The row being dragged follows: its field shows the number, the other
///   axis of a linked control, a sound row's slider and an animated
///   control's keyframes (a value dragged where it has none gets one, in its
///   diamond and its lane, at once) and its reset button, which appears
///   with the first step (`ResetWhenChanged`, a view of its own, so the
///   rows around it aren't redrawn), read `held`, so the control is
///   consistent with itself.
/// - Everything else shows the project as it was until the drag ends: the
///   Inspector's numbers and other copies of the value, the timeline's
///   volume lines and lanes, the EQ's band rows beside its
///   graph, thumbnails. Each would run again on every step,
///   which is what holding the drag avoids, and each is a second place
///   for what the dragged control already shows. Autosave and undo see the
///   project before the drag.
///
/// Each step is worked out from the project as it was before the drag
/// (a dragged field sets the value the drag has reached, not a change to
/// it), so `held` is always the whole drag so far. The writes inside one
/// step follow each other, though: a step that sets two things (a box's
/// frequencies and its levels) keeps both.
@MainActor
@Observable
final class ProjectState {
    private var committed: EditingProject
    /// The project with the drag so far, while one is held; nil otherwise.
    private(set) var held: EditingProject?
    /// Between `beginHold` and `endHold`, until `letGo`.
    @ObservationIgnored private(set) var isHolding = false
    /// Inside `hold`: writes go to `held`.
    @ObservationIgnored private var isCapturing = false
    /// What the step has written so far, which its next write starts from.
    @ObservationIgnored private var stepResult: EditingProject?

    init(_ project: EditingProject) {
        committed = project
        committed.stampEdit(since: nil)
    }

    /// The project. Read during a drag, it is the project from before it.
    /// A write that would change a locked clip, by anyone but the clip's
    /// owner, is refused (`lock(_:in:)`).
    var value: EditingProject {
        get { isCapturing ? stepResult ?? committed : committed }
        set {
            guard admits(newValue) else { return refuse() }
            // Every write is an edit, which views tell by its stamp
            // rather than by comparing projects (see `EditStamp`).
            var stamped = newValue
            stamped.stampEdit(since: value)
            if isCapturing {
                held = stamped
                stepResult = stamped
            } else {
                committed = stamped
            }
        }
    }

    /// Starts holding a drag's steps (see `hold`).
    func beginHold() {
        isHolding = true
        held = nil
    }

    /// Runs a step of the drag, whose writes to `value` go to `held` while
    /// the drag is held. Once let go, or without a drag, they go to the
    /// project.
    func hold(_ step: () -> Void) {
        guard isHolding else { return step() }
        isCapturing = true
        stepResult = nil
        defer { isCapturing = false }
        step()
    }

    /// Stops holding and drops what was held. The drag's owner then writes
    /// its last value to the project, or nothing, if it was cancelled.
    func endHold() {
        isHolding = false
        held = nil
    }

    /// Writes the drag so far to the project and lets the rest of it go
    /// straight there too, for a step the viewer can't draw from `held`
    /// alone (it changed what the player is built from, or it is playing).
    func letGo() {
        guard isHolding else { return }
        isHolding = false
        if let held { committed = held }
        held = nil
    }

    // MARK: Locked clips

    /// Clips a tool edits itself while it is open, which nothing else may
    /// change meanwhile: the motion designer's run. The tool writes them as
    /// their owner (`write(as:_:)`).
    struct ClipLock: Equatable {
        let timelineID: UUID
        let clipIDs: Set<UUID>

        /// Whether going from `old` to `new` changes one of the clips:
        /// anything about it, its layer, or its being there at all. A
        /// different project (one opened in its place) changes nothing.
        func isChanged(from old: EditingProject, to new: EditingProject) -> Bool {
            guard old.id == new.id else { return false }
            for id in clipIDs {
                let before = old.clipAndLayer(id, in: timelineID), after = new.clipAndLayer(id, in: timelineID)
                if before?.clip != after?.clip || before?.layer.id != after?.layer.id { return true }
            }
            return false
        }
    }

    /// Who is writing: anyone, a lock's owner, or the editor bringing what
    /// follows from an edit up to date (`writeDerived`).
    private enum Writer {
        case anyone
        case owner(UUID)
        case derived
    }

    @ObservationIgnored private var locks: [UUID: ClipLock] = [:]
    @ObservationIgnored private var writer = Writer.anyone
    /// The clips locked now, for views to show them as such.
    private(set) var lockedClipIDs: Set<UUID> = []
    /// Called when a write is refused; the app beeps.
    @ObservationIgnored var onRefused: () -> Void = {}

    /// Locks clips of a timeline against every write but their owner's,
    /// and gives the key that owns them.
    func lock(_ clipIDs: Set<UUID>, in timelineID: UUID) -> UUID {
        let key = UUID()
        locks[key] = ClipLock(timelineID: timelineID, clipIDs: clipIDs)
        lockedClipIDs.formUnion(clipIDs)
        return key
    }

    func unlock(_ key: UUID) {
        locks[key] = nil
        lockedClipIDs = locks.values.reduce(into: []) { $0.formUnion($1.clipIDs) }
    }

    /// Runs `body`, whose writes may change the clips `key` locks.
    func write(as key: UUID, _ body: () -> Void) {
        let outer = writer
        writer = .owner(key)
        defer { writer = outer }
        body()
    }

    /// Runs `body`, whose writes bring what follows from an edit up to date
    /// (keyframing effects making their keyframes again), which locked
    /// clips take too: they aren't an edit of anyone's.
    func writeDerived(_ body: () -> Void) {
        let outer = writer
        writer = .derived
        defer { writer = outer }
        body()
    }

    /// Whether anyone may make the project `project`, as undo would.
    func allows(_ project: EditingProject) -> Bool {
        !locks.values.contains { $0.isChanged(from: value, to: project) }
    }

    /// Whether the writer now may make the project `project`.
    private func admits(_ project: EditingProject) -> Bool {
        guard !locks.isEmpty else { return true }
        let current = value
        switch writer {
        case .derived:
            return true
        case .owner(let key):
            return !locks.contains { $0.key != key && $0.value.isChanged(from: current, to: project) }
        case .anyone:
            return !locks.values.contains { $0.isChanged(from: current, to: project) }
        }
    }

    private func refuse() {
        onRefused()
    }
}
