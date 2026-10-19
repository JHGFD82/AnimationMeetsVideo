import Testing
@testable import AnimationMeetsVideo

@MainActor
struct ProjectStateTests {
    @Test func aHeldStepGoesToHeldAndLeavesTheProject() {
        let state = ProjectState(.empty)
        state.beginHold()
        state.hold { state.value.name = "Dragged" }
        #expect(state.held?.name == "Dragged")
        #expect(state.value.name == "Untitled Project")
    }

    @Test func writesWithinAStepFollowEachOther() {
        let state = ProjectState(.empty)
        state.beginHold()
        state.hold {
            state.value.name = "Name"
            state.value.canvasMargin = 2
        }
        #expect(state.held?.name == "Name")
        #expect(state.held?.canvasMargin == 2)
    }

    @Test func eachStepStartsFromTheProjectBeforeTheDrag() {
        let state = ProjectState(.empty)
        state.beginHold()
        state.hold { state.value.name = "First" }
        state.hold { state.value.canvasMargin = 2 }
        // The second step doesn't carry the first's name.
        #expect(state.held?.name == "Untitled Project")
        #expect(state.held?.canvasMargin == 2)
    }

    @Test func withoutAHoldStepsWriteToTheProject() {
        let state = ProjectState(.empty)
        state.hold { state.value.name = "Plain" }
        #expect(state.held == nil)
        #expect(state.value.name == "Plain")
    }

    @Test func endingTheHoldDropsWhatWasHeld() {
        let state = ProjectState(.empty)
        state.beginHold()
        state.hold { state.value.name = "Dragged" }
        state.endHold()
        #expect(state.held == nil)
        #expect(state.value.name == "Untitled Project")
    }

    @Test func lettingGoWritesTheDragSoFarAndTheRestStraightThrough() {
        let state = ProjectState(.empty)
        state.beginHold()
        state.hold { state.value.name = "So far" }
        state.letGo()
        #expect(state.held == nil)
        #expect(state.value.name == "So far")
        state.hold { state.value.name = "After" }
        #expect(state.value.name == "After")
    }
}
