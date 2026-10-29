import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Drives a `ProjectHistory` the way the editor does: the app owns the
/// project value, and tells the history whenever it changes.
@MainActor
private final class Harness {
    var project = EditingProject.empty
    let history: ProjectHistory
    let undoManager = UndoManager()
    private var clock = Date(timeIntervalSince1970: 1_000)

    init() {
        history = ProjectHistory(project: project)
        history.undoManager = undoManager
        history.restore = { [unowned self] in project = $0 }
    }

    /// Applies an edit `gap` seconds after the previous one.
    func edit(after gap: TimeInterval = 10, _ change: (inout EditingProject) -> Void) {
        clock = clock.addingTimeInterval(gap)
        change(&project)
        history.projectDidChange(project, now: clock)
        closeEventGroup()
    }

    /// The undo manager groups registrations per run loop event, so let the
    /// loop turn the way it would between two user actions.
    func closeEventGroup() {
        let turn = Timer(timeInterval: 0, repeats: false) { _ in }
        RunLoop.current.add(turn, forMode: .default)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    func undo() {
        undoManager.undo()
        closeEventGroup()
        // The app reports the restored value back; it must not be recorded.
        history.projectDidChange(project, now: clock)
    }

    func redo() {
        undoManager.redo()
        closeEventGroup()
        history.projectDidChange(project, now: clock)
    }
}

@MainActor
@Suite struct ProjectHistoryTests {
    @Test func aGestureIsOneStepHoweverLongItTakes() {
        let h = Harness()
        h.edit { $0.name = "Before" }
        h.history.beginGesture()
        // Far apart in time, and several changes: still one step.
        h.edit(after: 5) { $0.name = "A" }
        h.edit(after: 5) { $0.name = "B" }
        h.edit(after: 5) { $0.name = "C" }
        h.history.endGesture(h.project)
        h.closeEventGroup()
        h.undo()
        #expect(h.project.name == "Before")
    }

    @Test func aQuietGestureIsOneStepAndDoesNotHoldTheViewer() {
        let h = Harness()
        h.edit { $0.name = "Before" }
        // The notifications are posted on this thread, as the gesture
        // begins and ends.
        final class Count: @unchecked Sendable { var value = 0 }
        let told = Count()
        let observers = [Notification.Name.valueGestureDidBegin, .valueGestureDidEnd].map {
            NotificationCenter.default.addObserver(forName: $0, object: h.history, queue: nil) { _ in told.value += 1 }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        h.history.beginGesture(quietly: true)
        h.edit(after: 5) { $0.name = "A" }
        h.edit(after: 5) { $0.name = "B" }
        h.history.endGesture(h.project)
        h.closeEventGroup()
        #expect(told.value == 0)
        h.undo()
        #expect(h.project.name == "Before")
    }

    @Test func aGesturePutBackLeavesNoStep() {
        let h = Harness()
        h.edit { $0.name = "Before" }
        h.undoManager.removeAllActions()
        h.history.beginGesture()
        h.edit(after: 1) { $0.name = "Moved" }
        h.edit(after: 1) { $0.name = "Before" }
        h.history.endGesture(h.project)
        #expect(!h.undoManager.canUndo)
    }

    @Test func undoRestoresPreviousProjectAndRedoReappliesIt() {
        let h = Harness()
        h.edit { $0.name = "First" }
        h.edit { $0.name = "Second" }

        h.undo()
        #expect(h.project.name == "First")
        h.undo()
        #expect(h.project.name == "Untitled Project")
        #expect(!h.undoManager.canUndo)

        h.redo()
        #expect(h.project.name == "First")
        h.redo()
        #expect(h.project.name == "Second")
        #expect(!h.undoManager.canRedo)
    }

    @Test func rapidChangesMergeIntoOneStep() {
        let h = Harness()
        h.edit { $0.name = "A" }
        h.edit(after: 0.1) { $0.name = "AB" }
        h.edit(after: 0.1) { $0.name = "ABC" }

        h.undo()
        #expect(h.project.name == "Untitled Project")
        #expect(!h.undoManager.canUndo)
    }

    @Test func changesFarApartAreSeparateSteps() {
        let h = Harness()
        h.edit { $0.name = "A" }
        h.edit(after: 2) { $0.name = "B" }

        h.undo()
        #expect(h.project.name == "A")
    }

    @Test func newEditAfterUndoClearsRedo() {
        let h = Harness()
        h.edit { $0.name = "A" }
        h.undo()
        #expect(h.undoManager.canRedo)

        h.edit { $0.name = "B" }
        #expect(!h.undoManager.canRedo)
        #expect(h.project.name == "B")
    }

    @Test func unchangedProjectRecordsNothing() {
        let h = Harness()
        h.edit { _ in }
        #expect(!h.undoManager.canUndo)
    }

    @Test func resetDiscardsHistoryAndTreatsNewProjectAsBaseline() {
        let h = Harness()
        h.edit { $0.name = "A" }

        var opened = EditingProject.empty
        opened.name = "Opened"
        h.project = opened
        h.history.reset(to: opened)
        h.history.projectDidChange(h.project)

        #expect(!h.undoManager.canUndo)
        #expect(!h.undoManager.canRedo)
    }

    @Test func adoptedChangesAreNotUndoable() {
        let h = Harness()
        h.project.name = "Saved As"
        h.history.adopt { $0.name = "Saved As" }
        h.history.projectDidChange(h.project)

        #expect(!h.undoManager.canUndo)
    }

    @Test func undoAfterSaveAsKeepsMediaWhereTheSaveMovedIt() {
        let h = Harness()
        let old = URL(fileURLWithPath: "/Old.amv/Media/clip.mov")
        let new = URL(fileURLWithPath: "/New.amv/Media/clip.mov")
        let media = MediaClip(
            name: "Clip", kind: .video, url: old,
            duration: .init(seconds: 5, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
        h.edit { $0.addMedia(media) }
        h.edit { $0.name = "Edited" }

        // Save As copies the file into the new package.
        let original = h.project
        var saved = original
        saved.clips[0].url = new
        h.history.adoptMediaLocations(of: original, from: saved)
        h.project.applyMediaLocations(from: saved)
        h.history.projectDidChange(h.project)

        h.undo()
        #expect(h.project.name == "Untitled Project")
        #expect(h.project.clips.first?.url == new)
        h.redo()
        #expect(h.project.clips.first?.url == new)
    }

    /// Saving after every change listens for edits landing: each edit, a
    /// gesture once when it ends (never during it), and undo.
    @Test func tellsWhenAnEditLands() {
        let h = Harness()
        var landed = 0
        h.history.changeLanded = { landed += 1 }
        h.edit { $0.name = "A" }
        #expect(landed == 1)

        h.history.beginGesture(quietly: true)
        h.edit(after: 5) { $0.name = "B" }
        h.edit(after: 5) { $0.name = "C" }
        #expect(landed == 1)
        h.history.endGesture(h.project)
        #expect(landed == 2)

        h.undo()
        #expect(landed == 3)
    }

    @Test func stepsAreNamedForTheEditMenu() {
        let h = Harness()
        h.edit { $0.name = "Renamed" }
        #expect(h.undoManager.undoActionName == "Rename Project to \u{201C}Renamed\u{201D}")
        h.undo()
        #expect(h.undoManager.redoActionName == "Rename Project to \u{201C}Renamed\u{201D}")
    }

    @Test func quickEditsOfDifferentKindsStaySeparate() {
        let h = Harness()
        h.edit { $0.name = "Renamed" }
        h.edit(after: 0.1) { $0.clips.append(MediaClip(
            name: "Clip", kind: .video, url: nil,
            duration: .init(seconds: 5, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )) }
        h.undo()
        #expect(h.project.clips.isEmpty)
        #expect(h.project.name == "Renamed")
    }

    @Test func undoingTimelineEditsRestoresClips() {
        let h = Harness()
        let media = MediaClip(
            name: "Clip", kind: .video, url: nil,
            duration: .init(seconds: 5, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
        h.edit { _ = $0.importClip(media, intoTimeline: $0.rootTimelineID) }
        #expect(h.project.timelines[0].layers.count == 1)

        h.undo()
        #expect(h.project.timelines[0].layers.isEmpty)
        #expect(h.project.clips.isEmpty)

        h.redo()
        #expect(h.project.timelines[0].layers.count == 1)
        #expect(h.project.clips.count == 1)
    }
}
