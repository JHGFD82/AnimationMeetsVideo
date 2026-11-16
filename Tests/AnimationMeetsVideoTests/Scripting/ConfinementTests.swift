import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The expressions' helper in its sandbox (docs/python-scripting.md,
/// "Safety"): it still runs Python, and the network, a file write, a
/// subprocess and a read in the home folder are each refused. Needs a Mac
/// and a real interpreter: `AMV_PYTHON=<python3> swift test --filter
/// Confinement`.
@Suite(.serialized, .enabled(if: ConfinementTests.canRun), .timeLimit(.minutes(2)))
struct ConfinementTests {
    static var canRun: Bool { PythonHelperTests.python != nil && HelperConfinement.isAvailable }

    private func helper() -> PythonHelper {
        let python = PythonHelperTests.python!
        return PythonHelper(interpreter: { PythonInterpreter(executable: python, source: .development) }, confined: true)
    }

    /// What `code` gives, run confined: its last line's value, shown.
    private func run(_ code: String) async throws -> String? {
        let helper = helper()
        defer { Task { await helper.shutDown() } }
        let end = try await helper.run(HelperRequest(kind: .line, code: code), output: { _ in }, answer: { _ in .error(.value("no calls")) })
        guard case .finished(let display) = end else {
            Issue.record("The run failed: \(end)")
            return nil
        }
        return display
    }

    /// `attempt` run in a try, giving "'allowed'" when it works and the
    /// exception's name when it is refused.
    private func outcome(_ attempt: String) async throws -> String? {
        let indented = attempt.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
        return try await run("""
        try:
        \(indented)
            result = "allowed"
        except Exception as error:
            result = type(error).__name__
        result
        """)
    }

    @Test func pythonStillRunsAndImportsTheStandardLibrary() async throws {
        #expect(try await run("import math, json, fractions, random\nmath.sqrt(16)") == "4.0")
    }

    @Test func theNetworkIsRefused() async throws {
        let result = try await outcome("import socket\nsocket.create_connection((\"1.1.1.1\", 53), timeout=3).close()")
        #expect(result != "'allowed'")
    }

    @Test func writingAFileIsRefused() async throws {
        let probe = FileManager.default.temporaryDirectory.appending(path: "amv-confinement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        #expect(try await outcome("open(\"\(probe.path)\", \"w\").write(\"x\")") != "'allowed'")
        #expect(!FileManager.default.fileExists(atPath: probe.path))
    }

    @Test func startingAProcessIsRefused() async throws {
        #expect(try await outcome("import subprocess\nsubprocess.run([\"/bin/echo\", \"x\"], check=True)") != "'allowed'")
        #expect(try await outcome("import os\nassert os.system(\"/bin/echo x\") == 0") != "'allowed'")
    }

    @Test func readingTheHomeFolderIsRefused() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(try await outcome("import os\nos.listdir(\"\(home)\")") != "'allowed'")
    }

    @Test func theScriptsHelperIsntConfined() async throws {
        let python = PythonHelperTests.python!
        let helper = PythonHelper(interpreter: { PythonInterpreter(executable: python, source: .development) })
        defer { Task { await helper.shutDown() } }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let end = try await helper.run(
            HelperRequest(kind: .line, code: "import os\nisinstance(os.listdir(\"\(home)\"), list)"),
            output: { _ in }, answer: { _ in .error(.value("no calls")) }
        )
        #expect(end == .finished(display: "True"))
    }

}

/// The profile itself, which needs no Mac to read.
@Suite struct ConfinementProfileTests {
    @Test func theProfileQuotesItsPathsAndAllowsNoNetwork() {
        let profile = HelperConfinement.profile(
            interpreter: URL(filePath: "/opt/py \"x\"/bin/python3"), host: URL(filePath: "/App/Python/amv_host/__main__.py")
        )
        #expect(profile.contains(#"(subpath "/opt/py \"x\"")"#))
        #expect(profile.contains(#"(subpath "/App/Python")"#))
        #expect(profile.contains("(deny default)"))
        #expect(!profile.contains("(allow network") && !profile.contains("process-fork") && !profile.contains("file-write*"))
    }
}
