import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The helper on a real interpreter: `AMV_PYTHON=<python3> swift test
/// --filter "PythonHelper|Confinement"`. Skipped when the variable isn't set.
@Suite(.serialized, .enabled(if: TestPython.interpreter != nil), .timeLimit(.minutes(2)))
struct PythonHelperTests {
    static let python = TestPython.interpreter

    private func helper() -> PythonHelper {
        let python = Self.python!
        return PythonHelper(interpreter: { PythonInterpreter(executable: python, source: .development) })
    }

    /// Answers every call with an error, for code that shouldn't make any.
    private let noCalls: @Sendable (HelperCall) async -> HelperReply = { .error(.value("No calls here: \($0.method)")) }

    @Test func pingNamesTheVersion() async throws {
        let helper = helper()
        let pong = try await helper.ping()
        #expect(pong.version?.isSupported == true)
        await helper.shutDown()
    }

    @Test func aLineGivesItsValueAndWhatItPrinted() async throws {
        let helper = helper()
        let printed = Printed()
        let end = try await helper.run(HelperRequest(kind: .line, code: "print('hi')\n6 * 7"), output: printed.add, answer: noCalls)
        #expect(end == .finished(display: "42"))
        #expect(printed.text == "hi\n")
        await helper.shutDown()
    }

    @Test func aCallIsAnsweredByTheApp() async throws {
        let helper = helper()
        let end = try await helper.run(
            HelperRequest(kind: .line, code: "amv.project.name"), output: { _ in },
            answer: { call in call.method == "project" ? .value(["id": "P", "name": "Demo", "root": "T", "timelines": [], "assets": []]) : .error(.value("?")) }
        )
        #expect(end == .finished(display: "'Demo'"))
        await helper.shutDown()
    }

    @Test func anErrorNamesItsLine() async throws {
        let helper = helper()
        let end = try await helper.run(HelperRequest(kind: .line, code: "x = 1\ntim"), output: { _ in }, answer: noCalls)
        guard case .failed(let failure) = end else { Issue.record("Expected an error, got \(end)"); return }
        #expect(failure.summary == "Line 2: NameError: name 'tim' is not defined")
        await helper.shutDown()
    }

    @Test func stopRaisesKeyboardInterrupt() async throws {
        let helper = helper()
        async let end = helper.run(HelperRequest(kind: .line, code: "while True:\n    pass"), output: { _ in }, answer: noCalls)
        try await Task.sleep(for: .milliseconds(500))
        await helper.stop()
        guard case .failed(let failure) = try await end else { Issue.record("Expected it stopped"); return }
        #expect(failure.wasStopped)
        // The same helper runs on.
        #expect(try await helper.run(HelperRequest(kind: .line, code: "1"), output: { _ in }, answer: noCalls) == .finished(display: "1"))
        await helper.shutDown()
    }

    @Test func codeThatIgnoresStopIsEndedASecondLater() async throws {
        let helper = helper()
        let code = "while True:\n    try:\n        while True: pass\n    except KeyboardInterrupt:\n        pass"
        async let end = helper.run(HelperRequest(kind: .line, code: code), output: { _ in }, answer: noCalls)
        try await Task.sleep(for: .milliseconds(500))
        await helper.stop()
        guard case .failed(let failure) = try await end else { Issue.record("Expected it stopped"); return }
        #expect(failure.wasStopped)
        // A new helper answers the next run.
        #expect(try await helper.run(HelperRequest(kind: .line, code: "2"), output: { _ in }, answer: noCalls) == .finished(display: "2"))
        await helper.shutDown()
    }

    @Test func theTimeLimitStopsARun() async throws {
        let helper = helper()
        var request = HelperRequest(kind: .line, code: "import time\ntime.sleep(30)")
        request.timeLimit = .milliseconds(300)
        await #expect(throws: ScriptHelperError.tookTooLong(.milliseconds(300))) {
            try await helper.run(request, output: { _ in }, answer: noCalls)
        }
        await helper.shutDown()
    }

    @Test func aHelperThatDiesMidRunIsReportedAndReplaced() async throws {
        let helper = helper()
        await #expect(throws: ScriptHelperError.self) {
            try await helper.run(HelperRequest(kind: .line, code: "import os\nos._exit(9)"), output: { _ in }, answer: noCalls)
        }
        #expect(try await helper.run(HelperRequest(kind: .line, code: "3"), output: { _ in }, answer: noCalls) == .finished(display: "3"))
        await helper.shutDown()
    }

    /// The helper's own unittests, which drive it against a fake app.
    @Test func theHelpersOwnTestsPass() throws {
        let tests = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Python")
        let process = Process()
        process.executableURL = Self.python
        process.arguments = ["-B", "-m", "unittest", "discover", "-s", tests.path]
        process.environment = ["AMV_PYTHON": Self.python!.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(text)")
    }
}

/// What a run printed, gathered from the helper's thread.
final class Printed: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []

    var add: @Sendable (ScriptOutput) -> Void {
        { [self] output in
            lock.lock()
            parts.append(output.text)
            lock.unlock()
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return parts.joined()
    }
}
