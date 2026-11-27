import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Opening a project (`ProjectSession.open`).
@MainActor
@Suite(.serialized) struct OpeningProjectTests {
    /// Another tool's folder holding a `project.json` is refused, and left
    /// as it was: it was marked a package, which Finder then shows as one
    /// document, and given a `.lock`, before its file was refused
    /// (code-review-notes.md, F74). The refusal names it.
    @Test func aFolderThatIsntAProjectIsLeftAsItWas() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "amv-not-a-project-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"x": 1}"#.utf8).write(to: folder.appending(path: ProjectStore.projectFileName))

        final class Said { var titles: [String] = [] }
        let said = Said()
        let session = ProjectSession()
        session.presentAlert = { title, _ in said.titles.append(title) }
        #expect(!(await session.open(folder)))
        #expect(said.titles.count == 1)
        #expect(said.titles.first?.contains(folder.lastPathComponent) == true)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: ProjectStore.lockFileName).path))
        let values = try folder.resourceValues(forKeys: [.isPackageKey])
        #expect(values.isPackage != true)
    }
}
