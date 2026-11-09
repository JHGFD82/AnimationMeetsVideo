import Testing
@testable import AnimationMeetsVideo

@MainActor
struct BrowserSkimEndingTests {
    @Test func clickingAnotherPanelEndsTheSkim() {
        #expect(BrowserSkimEnding.endsSkim(.timeline))
        #expect(BrowserSkimEnding.endsSkim(.sidePanel))
        #expect(BrowserSkimEnding.endsSkim(.effectsLibrary))
    }

    @Test func theBrowserAndViewerKeepIt() {
        // The viewer's own transport plays the skimmed clip.
        #expect(!BrowserSkimEnding.endsSkim(.browser))
        #expect(!BrowserSkimEnding.endsSkim(.viewer))
    }
}
