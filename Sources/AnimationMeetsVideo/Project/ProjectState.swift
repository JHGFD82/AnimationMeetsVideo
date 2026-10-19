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
/// Each step is worked out from the project as it was before the drag
/// (a dragged field sets the value the drag has reached, not a change to
/// it), so `held` is always the whole drag so far.
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

    init(_ project: EditingProject) {
        committed = project
    }

    /// The project. Read during a drag, it is the project from before it.
    var value: EditingProject {
        get { committed }
        set {
            if isCapturing {
                held = newValue
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
