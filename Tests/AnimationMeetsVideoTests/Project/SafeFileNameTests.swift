import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Names made into file names (code-review-notes.md, F51).
@Suite struct SafeFileNameTests {
    @Test func aNameCantLeaveItsFolder() {
        #expect(SafeFileName.make("../../Desktop/x", fallback: "F") == "-..-Desktop-x")
        #expect(SafeFileName.make("..", fallback: "F") == "F")
        #expect(SafeFileName.make(" .hidden ", fallback: "F") == "hidden")
        #expect(SafeFileName.make("a:b\\c", fallback: "F") == "a-b-c")
        #expect(SafeFileName.make("Cut 2", fallback: "F") == "Cut 2")
    }

    /// A project named to climb out of the backups folder is backed up
    /// inside it.
    @Test func aBackupStaysInItsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amv-safe-\(UUID().uuidString)", directoryHint: .isDirectory)
        let package = root.appending(path: "Cut.amv", directoryHint: .isDirectory)
        try ProjectStore.preparePackage(at: package)
        defer { try? FileManager.default.removeItem(at: root) }
        var project = EditingProject.empty
        project.name = "../../Escape"
        let backup = try ProjectBackups.write(project, packageURL: package)
        let folder = ProjectBackups.folder(forPackage: package).standardizedFileURL.path
        #expect(backup.standardizedFileURL.deletingLastPathComponent().path == folder)
    }
}
