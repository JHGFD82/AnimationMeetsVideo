import Testing
@testable import AnimationMeetsVideo

struct ProjectSessionAutosaveTests {
    @Test func savingOnlyWhenAskedAlwaysAutosaves() {
        #expect(ProjectSession.autosaveIsNeeded(savingAutomatically: false, inGesture: false, automaticSaveFailed: false))
    }

    @Test func savingAfterEveryChangeSkipsTheAutosave() {
        #expect(!ProjectSession.autosaveIsNeeded(savingAutomatically: true, inGesture: false, automaticSaveFailed: false))
    }

    @Test func aGestureHoldsEditsBackSoTheyAreAutosaved() {
        // A motion designer session is one gesture, saved only when it ends.
        #expect(ProjectSession.autosaveIsNeeded(savingAutomatically: true, inGesture: true, automaticSaveFailed: false))
    }

    @Test func failingSavesAreCoveredByTheAutosave() {
        #expect(ProjectSession.autosaveIsNeeded(savingAutomatically: true, inGesture: false, automaticSaveFailed: true))
    }
}
