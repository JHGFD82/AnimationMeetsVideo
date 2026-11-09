import Foundation
import SwiftUI
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

    @Test func everyFileThatFailsIsReportedInOneMessage() async {
        var project = EditingProject.empty
        let binding = Binding(get: { project }, set: { project = $0 })
        var errors: [String] = []
        let missing = ["Gone A.mov", "Gone B.mov", "Gone C.wav"].map {
            FileManager.default.temporaryDirectory.appending(path: "amv-missing-\(UUID().uuidString)").appending(path: $0)
        }
        let imported = await MediaImportFlow.importFiles(
            missing, copying: [], packageURL: nil, project: binding, onError: { errors.append($0) }
        )
        #expect(imported.isEmpty)
        #expect(errors.count == 1)
        let message = errors.first ?? ""
        #expect(message.hasPrefix("3 files couldn't be imported."))
        for name in ["Gone A.mov", "Gone B.mov", "Gone C.wav"] { #expect(message.contains(name)) }
    }

    @Test func oneFailureIsReportedAsItIs() {
        #expect(MediaImportFlow.failureMessage([]) == nil)
        #expect(MediaImportFlow.failureMessage(["a.mov: It is gone."]) == "a.mov: It is gone.")
    }
}
