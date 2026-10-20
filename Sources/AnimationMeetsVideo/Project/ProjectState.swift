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
    }

    /// The project. Read during a drag, it is the project from before it.
    var value: EditingProject {
        get { isCapturing ? stepResult ?? committed : committed }
        set {
            if isCapturing {
                held = newValue
                stepResult = newValue
            } else {
                committed = newValue
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
}
