import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor @Suite struct MediaImportFlowTests {
    @Test func takesMoviesSoundAndPicturesFromTheFinderOnly() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.mov"),
            URL(fileURLWithPath: "/tmp/b.wav"),
            URL(fileURLWithPath: "/tmp/c.png"),
            URL(fileURLWithPath: "/tmp/d.txt"),
            URL(fileURLWithPath: "/tmp/e"),
            URL(string: "amv-effect:blur")!,
        ]
        #expect(MediaImportFlow.importable(urls).map(\.lastPathComponent) == ["a.mov", "b.wav", "c.png"])
    }
}
