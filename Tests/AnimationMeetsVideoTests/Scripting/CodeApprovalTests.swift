import Foundation
import Testing
@testable import AnimationMeetsVideo

/// What may run on this Mac (docs/python-scripting.md, "Safety").
@MainActor @Suite struct CodeApprovalTests {
    private let file = FileManager.default.temporaryDirectory.appending(path: "amv-allowed-\(UUID().uuidString).json")

    @Test func codeIsAllowedByItsExactText() {
        defer { try? FileManager.default.removeItem(at: file) }
        let approval = CodeApproval(file: file)
        approval.allow("value + 1")
        #expect(approval.isAllowed("value + 1"))
        // One character changed outside the app makes it unallowed again.
        #expect(!approval.isAllowed("value + 2"))
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
        CodeApproval(file: file).allow("print(1)")
        #expect(CodeApproval(file: file).isAllowed("print(1)"))
    }

    /// Approval is of content only (decision D5): the list keeps hashes,
    /// and no project, by ID or path, is in it to vouch for what arrives
    /// there later.
    @Test func noProjectIsRemembered() throws {
        defer { try? FileManager.default.removeItem(at: file) }
        CodeApproval(file: file).allow("print(1)")
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(Set(stored?.keys.map { $0 } ?? []) == ["formatVersion", "code"])
    }

    @Test func forgettingForgetsEverything() {
        defer { try? FileManager.default.removeItem(at: file) }
        let approval = CodeApproval(file: file)
        approval.allow("1")
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

    /// The question says what an unrestricted script can do, what approval
    /// covers and what it doesn't.
    @Test func theQuestionSaysWhatApprovalCovers() {
        let alone = ScriptActions.approvalText(withFilesBeside: false)
        let beside = ScriptActions.approvalText(withFilesBeside: true)
        for text in [alone, beside] {
            #expect(text.contains("files") && text.contains("network") && text.contains("your permissions"))
            #expect(text.contains("asked again"))
            #expect(text.contains("aren't checked"))
        }
        #expect(beside.contains("the files in its folder"))
        #expect(!alone.contains("the files in its folder"))
    }
}

/// What a project's script is approved as and runs as (`ScriptSnapshot`).
@Suite struct ScriptSnapshotTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "amv-scripts-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func write(_ text: String, to name: String) throws {
        let url = folder.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private var script: URL { folder.appending(path: "Tidy.py") }
    private let text = "\"\"\"Tidy\"\"\"\nimport util\n"

    /// A project's script runs with its folder first on Python's import
    /// path, so approving it approves the files beside it too: one
    /// changed or added there asks again, rather than running unseen.
    @Test func approvalCoversTheFilesBesideIt() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(text, to: "Tidy.py")
        // Alone in its folder, a script is approved by its text.
        #expect(try ScriptSnapshot.take(of: script).approvalCode == text)

        try write("WORD = 1\n", to: "util.py")
        let approved = try ScriptSnapshot.take(of: script).approvalCode
        #expect(approved != text)
        try write("open('/tmp/x', 'w')\n", to: "util.py")
        #expect(try ScriptSnapshot.take(of: script).approvalCode != approved)
        try write("WORD = 1\n", to: "util.py")
        #expect(try ScriptSnapshot.take(of: script).approvalCode == approved)
        try write("", to: "lib/csv.py")
        #expect(try ScriptSnapshot.take(of: script).approvalCode != approved)
    }

    /// A link could point outside the folder, and be pointed elsewhere
    /// after approval: the script doesn't run.
    @Test func aLinkInTheFolderIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(text, to: "Tidy.py")
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "util.py"), withDestinationURL: URL(filePath: "/etc/hosts"))
        #expect(throws: ScriptSnapshot.Problem.link("util.py")) { try ScriptSnapshot.take(of: script) }
        try FileManager.default.removeItem(at: folder.appending(path: "util.py"))
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "lib"), withDestinationURL: URL(filePath: "/usr/lib"))
        #expect(throws: ScriptSnapshot.Problem.link("lib")) { try ScriptSnapshot.take(of: script) }
    }

    @Test func aLinkedScriptIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(text, to: "elsewhere/Real.py")
        let linked = folder.appending(path: "Linked.py")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: folder.appending(path: "elsewhere/Real.py"))
        #expect(throws: ScriptSnapshot.Problem.link("Linked.py")) { try ScriptSnapshot.take(of: linked) }
    }

    /// Compiled modules could run in place of their source: they are left
    /// out of what is approved and of the copy that runs.
    @Test func compiledModulesAreLeftOut() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(text, to: "Tidy.py")
        try write("WORD = 1\n", to: "util.py")
        let before = try ScriptSnapshot.take(of: script)
        try write("not really bytecode", to: "__pycache__/util.cpython-314.pyc")
        try write("", to: ".DS_Store")
        let after = try ScriptSnapshot.take(of: script)
        #expect(after.approvalCode == before.approvalCode)
        let copy = try after.materialize()
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(!FileManager.default.fileExists(atPath: copy.appending(path: "__pycache__").path))
    }

    /// What runs is what was read: a file changed after the snapshot
    /// (after approval) doesn't reach the copy imported from.
    @Test func theCopyHoldsWhatWasRead() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(text, to: "Tidy.py")
        try write("WORD = 1\n", to: "util.py")
        try write("", to: "lib/csv.py")
        let snapshot = try ScriptSnapshot.take(of: script)
        try write("WORD = 'changed after approval'\n", to: "util.py")
        try write("import os\n", to: "Tidy.py")
        let copy = try snapshot.materialize()
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(try String(contentsOf: copy.appending(path: "util.py"), encoding: .utf8) == "WORD = 1\n")
        #expect(try String(contentsOf: copy.appending(path: "Tidy.py"), encoding: .utf8) == text)
        #expect(FileManager.default.fileExists(atPath: copy.appending(path: "lib/csv.py").path))
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test func aFolderTooLargeToCheckIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(text, to: "Tidy.py")
        for index in 0...ScriptSnapshot.mostFiles { try write("", to: "many/\(index).txt") }
        #expect(throws: ScriptSnapshot.Problem.tooLarge) { try ScriptSnapshot.take(of: script) }
    }
}
