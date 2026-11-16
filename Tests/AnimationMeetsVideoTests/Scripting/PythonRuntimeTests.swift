import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct PythonRuntimeTests {
    private let defaults = UserDefaults(suiteName: "amv-python-runtime-\(UUID().uuidString)")!
    /// An executable file standing in for an interpreter.
    private let fake: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-fake-python-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return url
    }()

    @Test func theChosenOneComesFirstThenTheBuiltInThenAMVPython() {
        defer { try? FileManager.default.removeItem(at: fake) }
        let other = "/bin/sh"
        #expect(PythonRuntime.interpreter(defaults: defaults, environment: [:], builtIn: nil) == nil)
        #expect(PythonRuntime.interpreter(defaults: defaults, environment: ["AMV_PYTHON": other], builtIn: nil)
            == PythonInterpreter(executable: URL(filePath: other), source: .development))
        #expect(PythonRuntime.interpreter(defaults: defaults, environment: ["AMV_PYTHON": other], builtIn: fake)?.source == .builtIn)
        defaults.set(fake.path, forKey: Preferences.pythonInterpreter)
        #expect(PythonRuntime.interpreter(defaults: defaults, environment: [:], builtIn: nil)?.source == .chosen)
    }

    @Test func aChosenOneThatIsGoneFallsBack() {
        defaults.set("/nowhere/python3", forKey: Preferences.pythonInterpreter)
        #expect(PythonRuntime.interpreter(defaults: defaults, environment: ["AMV_PYTHON": "/bin/sh"], builtIn: nil)?.source == .development)
    }

    @Test func theHelpersCodeShipsInTheResourceBundle() throws {
        let host = try #require(PythonRuntime.hostScript)
        #expect(FileManager.default.fileExists(atPath: host.path))
        #expect(FileManager.default.fileExists(atPath: host.deletingLastPathComponent().appending(path: "amv/__init__.py").path))
    }
}
