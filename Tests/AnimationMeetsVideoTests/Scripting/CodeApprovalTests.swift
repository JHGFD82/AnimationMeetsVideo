import Foundation
import Testing
@testable import AnimationMeetsVideo

/// What may run on this Mac (docs/python-scripting.md, "Safety").
@MainActor @Suite struct CodeApprovalTests {
    private let file = FileManager.default.temporaryDirectory.appending(path: "amv-allowed-\(UUID().uuidString).json")
    private let package = URL(filePath: "/Projects/Demo.amv")

    @Test func codeIsAllowedByItsExactText() {
        defer { try? FileManager.default.removeItem(at: file) }
        let approval = CodeApproval(file: file)
        approval.allow("value + 1")
        #expect(approval.isAllowed("value + 1"))
        // One character changed outside the app makes it unallowed again.
        #expect(!approval.isAllowed("value + 2"))
    }

    /// A project's script runs with its folder first on the import path,
    /// so allowing it allows the files beside it too: one changed or added
    /// there asks again, rather than running unseen with it.
    @Test func allowingAScriptCoversTheFilesBesideIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "amv-scripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: file)
        }
        let script = folder.appending(path: "Tidy.py")
        let text = "\"\"\"Tidy\"\"\"\nimport util\n"
        try Data(text.utf8).write(to: script)
        // Alone in its folder, a script is allowed by its text.
        #expect(CodeApproval.approvalCode(forScript: text, at: script) == text)

        let util = folder.appending(path: "util.py")
        try Data("WORD = 1\n".utf8).write(to: util)
        let approval = CodeApproval(file: file)
        approval.allow(CodeApproval.approvalCode(forScript: text, at: script))
        #expect(approval.isAllowed(CodeApproval.approvalCode(forScript: text, at: script)))
        #expect(!approval.isAllowed(text))

        try Data("open('/tmp/x', 'w')\n".utf8).write(to: util)
        #expect(!approval.isAllowed(CodeApproval.approvalCode(forScript: text, at: script)))
        try Data("WORD = 1\n".utf8).write(to: util)
        try FileManager.default.createDirectory(at: folder.appending(path: "lib"), withIntermediateDirectories: true)
        try Data("".utf8).write(to: folder.appending(path: "lib/csv.py"))
        #expect(!approval.isAllowed(CodeApproval.approvalCode(forScript: text, at: script)))
    }

    @Test func theModelReadsOnlyTheAppsOwnList() {
        defer { try? FileManager.default.removeItem(at: file) }
        let code = "value + \(UUID())"
        // Another list's code doesn't count for the model.
        CodeApproval(file: file).allow(code)
        #expect(!CodeApproval.allowsCode(code))
        CodeApproval.allowInSession(code)
        #expect(CodeApproval.allowsCode(code))
    }

    @Test func whatIsAllowedIsKeptOnThisMacBetweenLaunches() {
        defer { try? FileManager.default.removeItem(at: file) }
        let id = UUID()
        CodeApproval(file: file).allow("print(1)")
        CodeApproval(file: file).allowScripts(ofProject: id, at: package)
        let again = CodeApproval(file: file)
        #expect(again.isAllowed("print(1)"))
        #expect(again.allowsScripts(ofProject: id, at: package))
    }

    @Test func aProjectIsKnownByItsIDAndItsPlace() {
        defer { try? FileManager.default.removeItem(at: file) }
        let approval = CodeApproval(file: file)
        let id = UUID()
        approval.allowScripts(ofProject: id, at: package)
        #expect(approval.mayRun(script: "import amv", ofProject: id, at: package))
        // A copy arriving from elsewhere under the same ID asks again.
        #expect(!approval.mayRun(script: "import amv", ofProject: id, at: URL(filePath: "/Downloads/Demo.amv")))
        #expect(!approval.mayRun(script: "import amv", ofProject: UUID(), at: package))
    }

    @Test func saveAsKeepsWhatWasAllowed() {
        defer { try? FileManager.default.removeItem(at: file) }
        let approval = CodeApproval(file: file)
        let id = UUID()
        let moved = URL(filePath: "/Projects/Demo 2.amv")
        approval.allowScripts(ofProject: id, at: package)
        approval.projectMoved(id, from: package, to: moved)
        #expect(approval.allowsScripts(ofProject: id, at: moved))
    }

    @Test func aScriptAllowedOnceRunsUntilItChanges() {
        defer { try? FileManager.default.removeItem(at: file) }
        let approval = CodeApproval(file: file)
        let id = UUID()
        approval.allow("import amv\nprint(1)")
        #expect(approval.mayRun(script: "import amv\nprint(1)", ofProject: id, at: package))
        #expect(!approval.mayRun(script: "import amv\nprint(2)", ofProject: id, at: package))
    }

    @Test func forgettingForgetsEverything() {
        defer { try? FileManager.default.removeItem(at: file) }
        let approval = CodeApproval(file: file)
        approval.allow("1")
        approval.allowScripts(ofProject: UUID(), at: package)
        approval.forgetAll()
        #expect(approval.isEmpty)
        #expect(CodeApproval(file: file).isEmpty)
    }

    @Test func nothingIsReadFromAProject() throws {
        // A project's package holding a file of the same name vouches for
        // nothing: only the one in Application Support is read.
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(CodeApproval.defaultFile.path.contains("Application Support/AnimationMeetsVideo/AllowedCode.json"))
        #expect(CodeApproval(file: file).isEmpty)
    }
}
