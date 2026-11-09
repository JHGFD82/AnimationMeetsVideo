import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Clips locked in the project's state while the motion designer has them
/// open (`ProjectState.lock`): only their owner may change them.
@MainActor
struct ClipLockTests {
    /// Two clips on a layer, the first locked.
    private func fixture() -> (ProjectState, locked: TimelineClip, other: TimelineClip, key: UUID, refusals: () -> Int) {
        var project = EditingProject.empty
        let locked = TimelineClip(source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 2, timescale: 1))
        let other = TimelineClip(source: .adjustment, startOffset: CMTime(value: 4, timescale: 1), trimStart: .zero, trimEnd: CMTime(value: 2, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [locked, other])]
        let state = ProjectState(project)
        var count = 0
        state.onRefused = { count += 1 }
        let key = state.lock([locked.id], in: project.rootTimelineID)
        return (state, locked, other, key, { count })
    }

    private func clip(_ id: UUID, in state: ProjectState) -> TimelineClip? {
        state.value.clipAndLayer(id, in: state.value.rootTimelineID)?.clip
    }

    @Test func anEditToALockedClipIsRefusedWithASignal() {
        let (state, locked, _, _, refusals) = fixture()
        let timeline = state.value.rootTimelineID
        state.value.editClip(locked.id, in: timeline) { $0.startOffset = CMTime(value: 1, timescale: 1) }
        #expect(clip(locked.id, in: state) == locked)
        state.value.deleteClips([locked.id], in: timeline)
        #expect(clip(locked.id, in: state) == locked)
        #expect(refusals() == 2)
        #expect(state.lockedClipIDs == [locked.id])
    }

    @Test func otherClipsAndTheRestOfTheProjectStayEditable() {
        let (state, _, other, _, refusals) = fixture()
        let timeline = state.value.rootTimelineID
        state.value.editClip(other.id, in: timeline) { $0.startOffset = CMTime(value: 6, timescale: 1) }
        state.value.name = "Renamed"
        #expect(clip(other.id, in: state)?.startOffset == CMTime(value: 6, timescale: 1))
        #expect(state.value.name == "Renamed")
        #expect(refusals() == 0)
    }

    @Test func anEditTouchingALockedClipAmongOthersIsRefusedWhole() {
        let (state, locked, other, _, _) = fixture()
        let timeline = state.value.rootTimelineID
        state.value.deleteClips([locked.id, other.id], in: timeline)
        #expect(clip(locked.id, in: state) != nil && clip(other.id, in: state) != nil)
    }

    @Test func theOwnerAndDerivedWritesMayChangeIt() {
        let (state, locked, _, key, refusals) = fixture()
        let timeline = state.value.rootTimelineID
        state.write(as: key) {
            state.value.editClip(locked.id, in: timeline) { $0.startOffset = CMTime(value: 1, timescale: 1) }
        }
        #expect(clip(locked.id, in: state)?.startOffset == CMTime(value: 1, timescale: 1))
        state.writeDerived {
            state.value.editClip(locked.id, in: timeline) { $0.time.frameBlending = .blend }
        }
        #expect(clip(locked.id, in: state)?.time.frameBlending == .blend)
        #expect(refusals() == 0)
    }

    @Test func aHeldDragOnALockedClipIsRefusedToo() {
        let (state, locked, _, _, refusals) = fixture()
        let timeline = state.value.rootTimelineID
        state.beginHold()
        state.hold { state.value.editClip(locked.id, in: timeline) { $0.time.frameBlending = .blend } }
        #expect(state.held == nil)
        #expect(refusals() == 1)
    }

    @Test func unlockingFreesTheClipAndAnotherProjectIsntRefused() {
        let (state, locked, _, key, _) = fixture()
        let timeline = state.value.rootTimelineID
        #expect(!state.allows({ var p = state.value; p.deleteClips([locked.id], in: timeline); return p }()))
        // A project opened in its place has none of the clips, and isn't
        // an edit of them.
        #expect(state.allows(.empty))
        state.unlock(key)
        #expect(state.lockedClipIDs.isEmpty)
        state.value.deleteClips([locked.id], in: timeline)
        #expect(clip(locked.id, in: state) == nil)
    }

    @Test func undoThatWouldChangeALockedClipIsRefusedAndKept() async throws {
        let (state, locked, _, key, _) = fixture()
        let timeline = state.value.rootTimelineID
        state.unlock(key)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let history = ProjectHistory(project: state.value)
        history.undoManager = undoManager
        history.restore = { state.value = $0 }
        var refused = 0
        history.onRefused = { refused += 1 }
        history.canRestore = { state.allows($0) }
        undoManager.beginUndoGrouping()
        state.value.editClip(locked.id, in: timeline) { $0.startOffset = CMTime(value: 1, timescale: 1) }
        history.projectDidChange(state.value)
        undoManager.endUndoGrouping()

        _ = state.lock([locked.id], in: timeline)
        // As in the app, where the step put back registers in an event.
        undoManager.groupsByEvent = true
        undoManager.undo()
        #expect(refused == 1)
        #expect(clip(locked.id, in: state)?.startOffset == CMTime(value: 1, timescale: 1))
        // The step goes back on the stack, for after the designer closes.
        try await Task.sleep(for: .milliseconds(50))
        #expect(undoManager.canUndo)
    }
}
