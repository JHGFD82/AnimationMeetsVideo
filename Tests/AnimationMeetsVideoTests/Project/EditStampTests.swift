import CoreMedia
import Testing
@testable import AnimationMeetsVideo

@MainActor
struct EditStampTests {
    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    @Test func everyWriteIsANewEdit() {
        let state = ProjectState(.empty)
        let first = state.value.editCount
        state.value.name = "Renamed"
        #expect(first != 0)
        #expect(state.value.editCount != first)
    }

    @Test func anUndoneEditAndTheNextOneDontShareACount() {
        let state = ProjectState(.empty)
        let before = state.value
        state.value.name = "A"
        let edited = state.value.editCount
        // Undo writes the older project back, then another edit follows.
        state.value = before
        state.value.name = "B"
        #expect(state.value.editCount != edited)
    }

    @Test func editingOneTimelineLeavesAnothersVersion() throws {
        let state = ProjectState(.empty)
        let main = state.value.rootTimelineID
        state.value.timelines.append(Timeline(
            name: "Other", layers: [], frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709
        ))
        let other = try #require(state.value.timelines.last?.id)
        let mainVersion = state.value.timeline(id: main)?.version
        let otherVersion = state.value.timeline(id: other)?.version
        _ = state.value.addSection(in: other, from: .zero, to: seconds(2))
        #expect(state.value.timeline(id: main)?.version == mainVersion)
        #expect(state.value.timeline(id: other)?.version != otherVersion)
    }

    @Test func stampsDontChangeWhatIsEqual() {
        var stamped = EditingProject.empty
        let plain = stamped
        stamped.stampEdit(since: nil)
        #expect(stamped == plain)
        #expect(stamped.timelines[0] == plain.timelines[0])
    }

    @Test func aHeldStepIsStampedToo() {
        let state = ProjectState(.empty)
        let committed = state.value.editCount
        state.beginHold()
        state.hold { state.value.name = "Dragged" }
        #expect(state.held.map(\.editCount) != committed)
        #expect(state.value.editCount == committed)
    }
}
