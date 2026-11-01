import CoreMedia
import Foundation

/// Where each timeline shown in a window was left (`ViewState`), for
/// opening it there again: its playhead and the clip selected, kept by the
/// editor surface, and its zoom and scroll, kept by the timeline. Each
/// keeps its part as a timeline is left, and says how to read the part of
/// the timeline open now (`capture`), for saving.
///
/// The project window's comes from its session, which reads and writes it
/// in the package (`ViewStateFile`); a window without one (a second window
/// on a timeline, the external display) keeps its own until it closes.
@MainActor
final class TimelineViewMemory {
    private(set) var state = ViewState()
    /// Read the open timeline's parts into `state`, keyed by who keeps
    /// them, so registering again replaces.
    private var captures: [String: () -> Void] = [:]
    /// What was last read or written, so an unchanged state isn't written.
    private var written = ViewState()
    /// The package it is saved in; nil for one that is never saved.
    private(set) var packageURL: URL?

    init(_ state: ViewState = ViewState()) {
        self.state = state
        written = state
    }

    // MARK: Keeping

    /// Changes what is kept for `timelineID`.
    func update(_ timelineID: UUID, _ change: (inout ViewState.Timeline) -> Void) {
        change(&state.timelines[timelineID, default: ViewState.Timeline()])
    }

    func noteOpen(_ timelineID: UUID) {
        state.openTimelineID = timelineID
    }

    /// Has `key`'s part of the open timeline read by `capture` before
    /// `snapshot()`.
    func register(_ key: String, capture: @escaping () -> Void) {
        captures[key] = capture
    }

    /// Everything kept, with the open timeline as it is now.
    func snapshot() -> ViewState {
        for capture in captures.values { capture() }
        return state
    }

    // MARK: Reading back

    func parked(_ timelineID: UUID) -> ViewState.Timeline? {
        state.timelines[timelineID]
    }

    /// The timeline open when the window was left, if the project still has it.
    func openTimeline(in project: EditingProject) -> UUID? {
        state.openTimelineID.flatMap { project.timeline(id: $0) != nil ? $0 : nil }
    }

    /// The playhead `timelineID` was left at, held back to its end if an
    /// edit since shortened it; its start the first time it is shown.
    func time(in timelineID: UUID, of project: EditingProject) -> CMTime {
        guard let time = parked(timelineID)?.time, time.isNumeric,
              let duration = project.timeline(id: timelineID)?.duration
        else { return .zero }
        return CMTimeMaximum(.zero, CMTimeMinimum(time, duration))
    }

    /// The clip selected when `timelineID` was left, if it is still there;
    /// its transition only if that is still there too.
    func selection(in timelineID: UUID, of project: EditingProject) -> TimelineSelection? {
        guard var selection = parked(timelineID)?.selection, selection.timelineID == timelineID,
              let clip = project.timelineClip(of: selection)
        else { return nil }
        if let edge = selection.transitionEdge, clip.transition(at: edge) == nil { selection.transitionEdge = nil }
        return selection
    }

    // MARK: Saving

    /// Takes up what `packageURL` holds, as a project opens, and saves
    /// there from then on.
    func load(from packageURL: URL) {
        state = ViewStateFile.read(from: packageURL)
        written = state
        self.packageURL = packageURL
    }

    /// Saves into `packageURL` from now on, as the project was saved there
    /// (Save As), writing everything there at the next save.
    func move(to packageURL: URL) {
        self.packageURL = packageURL
        written = ViewState()
    }

    /// Writes the state, with the open timeline as it is now, into its
    /// package when it changed since it was read or written, leaving out
    /// timelines `project` no longer has (deleted, or the empty project a
    /// window shows before its own opens). Nothing for one with no package.
    func save(for project: EditingProject) {
        guard let packageURL else { return }
        var state = snapshot()
        state.timelines = state.timelines.filter { project.timeline(id: $0.key) != nil }
        if let open = state.openTimelineID, project.timeline(id: open) == nil { state.openTimelineID = nil }
        self.state = state
        guard state != written else { return }
        do {
            try ViewStateFile.write(state, to: packageURL)
            written = state
        } catch {
            // Only where things were left: the next save tries again.
            NSLog("Couldn't save the view state: %@", error.localizedDescription)
        }
    }
}

extension EditingProject {
    /// The clip `selection` picks, if the project still has it there.
    func timelineClip(of selection: TimelineSelection) -> TimelineClip? {
        timeline(id: selection.timelineID)?.layer(id: selection.layerID)?.clips.first { $0.id == selection.timelineClipID }
    }
}
