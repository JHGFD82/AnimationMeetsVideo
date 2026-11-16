import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A project's `Scripts/` folder (docs/python-scripting.md, "Where
/// scripts live").
@MainActor @Suite(.serialized) struct ScriptLibraryTests {
    private let package = FileManager.default.temporaryDirectory
        .appending(path: "amv-scripts-\(UUID().uuidString).amv", directoryHint: .isDirectory)

    private func write(_ text: String, named name: String, in package: URL? = nil) throws {
        let folder = ScriptLibrary.folder(in: package ?? self.package)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appending(path: name))
    }

    @Test func aScriptIsTitledByItsDocstringsFirstLine() {
        #expect(ScriptFile.docstringTitle(of: "\"\"\"Stagger Selected Clips\"\"\"\nimport amv") == "Stagger Selected Clips")
        #expect(ScriptFile.docstringTitle(of: "#!/usr/bin/env python3\n# -*- coding: utf-8 -*-\n\n'''\n  Blur In\n\n  More.\n'''") == "Blur In")
        #expect(ScriptFile.docstringTitle(of: "r\"Raw title\"\n") == "Raw title")
        #expect(ScriptFile.docstringTitle(of: "import amv\n\"\"\"Too late\"\"\"") == nil)
        #expect(ScriptFile.docstringTitle(of: "\"\"\"\"\"\"") == nil)
        #expect(ScriptFile(url: URL(filePath: "/x/blur-in.py"), text: "pass").title == "blur-in")
    }

    @Test func thePackagesPyFilesAreListedByTitle() throws {
        defer { try? FileManager.default.removeItem(at: package) }
        try write("\"\"\"Zoom\"\"\"", named: "b.py")
        try write("\"\"\"Align\"\"\"", named: "a.py")
        try write("not a script", named: "shots.csv")
        #expect(ScriptLibrary.list(ScriptLibrary.folder(in: package)).map(\.title) == ["Align", "Zoom"])
    }

    @Test func aFileAddedIsPickedUpWithoutReopening() async throws {
        defer { try? FileManager.default.removeItem(at: package) }
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let library = ScriptLibrary()
        library.watch(package: package)
        #expect(library.scripts.isEmpty)
        try write("\"\"\"Added\"\"\"", named: "added.py")
        try await waitUntil("the added script is listed") { library.scripts.map(\.title) == ["Added"] }
        library.watch(package: nil)
    }

    @Test func newScriptMakesAFileThatIsntOverwritten() async throws {
        defer { try? FileManager.default.removeItem(at: package) }
        let first = try await ScriptLibrary.makeScript(named: "Blur In", in: package)
        let second = try await ScriptLibrary.makeScript(named: "Blur In", in: package)
        #expect(first.lastPathComponent == "Blur In.py" && second.lastPathComponent == "Blur In 2.py")
        #expect(ScriptFile(url: first, text: try String(contentsOf: first, encoding: .utf8)).title == "Blur In")
    }

    @Test func saveAsCarriesTheScripts() async throws {
        let other = FileManager.default.temporaryDirectory.appending(path: "amv-scripts-\(UUID().uuidString).amv", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: other)
        }
        try ProjectStore.preparePackage(at: package)
        try write("\"\"\"Kept\"\"\"", named: "kept.py")
        try write("a,b", named: "shots.csv")
        try await ProjectStore.save(EditingProject.empty, to: other, previousPackageURL: package)
        let folder = ScriptLibrary.folder(in: other)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "kept.py").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "shots.csv").path))
    }

    @Test func aBackupCarriesTheScripts() throws {
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.preparePackage(at: package)
        try write("\"\"\"Kept\"\"\"", named: "kept.py")
        let backup = try ProjectBackups.write(EditingProject.empty, packageURL: package)
        defer { try? FileManager.default.removeItem(at: ProjectBackups.folder(forPackage: package)) }
        #expect(FileManager.default.fileExists(atPath: ScriptLibrary.folder(in: backup).appending(path: "kept.py").path))
    }
}
