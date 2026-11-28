import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The expressions' helper in its sandbox (docs/python-scripting.md,
/// "Safety"): it still runs Python, and the network, a file write, a
/// subprocess and a read in the home folder are each refused. Needs a Mac
/// and a real interpreter: `AMV_PYTHON=<python3> swift test --filter
/// Confinement`.
@Suite(.serialized, .enabled(if: TestPython.interpreter != nil && HelperConfinement.isAvailable), .timeLimit(.minutes(2)))
struct ConfinementTests {
    private func helper() -> PythonHelper {
        let python = TestPython.interpreter!
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

    /// An expression asks the app for what it reads while it runs, as
    /// audio() and reading another control do: those calls work confined.
    @Test func callsToTheAppWorkMidRun() async throws {
        let helper = helper()
        defer { Task { await helper.shutDown() } }
        var request = HelperRequest(kind: .expression, code: "audio(20, 150) + noise(0.5)")
        let tables: [(String, Int, [Double])] = [
            ("time", 1, [0, 1.0 / 24]), ("t", 1, [0, 1.0 / 24]), ("frame", 1, [0, 1]), ("source_time", 1, [0, 1.0 / 24]),
            ("value", 1, [0, 0]), ("a", 1, [0, 0]), ("b", 1, [0, 0]), ("c", 1, [0, 0]), ("d", 1, [0, 0]),
        ]
        request.payload = PythonHelper.payload(tables.flatMap { $0.2 })
        request.fields = [
            "count": 2, "width": 1, "tables": .array(tables.map { [.string($0.0), .number(Double($0.1))] }),
            "fps": 24, "duration": 0.04, "seed": 1, "effect": "E",
        ]
        let end = try await helper.run(request, output: { _ in }, answer: { call in
            switch call.method {
            case "audio_levels": .value([0.25, 0.5])
            case "noise": .value([1])
            default: .error(.value("no \(call.method)"))
            }
        })
        #expect(end == .samples([1.25, 1.5]))
    }

    /// An error comes back as itself: writing it up mustn't need anything
    /// the sandbox refuses, as asking for the working folder did, which
    /// turned every error into "Operation not permitted".
    @Test func anErrorComesBackAsItself() async throws {
        let helper = helper()
        defer { Task { await helper.shutDown() } }
        let end = try await helper.run(
            HelperRequest(kind: .line, code: "x = 1\nraise ValueError(\"nothing to hear\")"),
            output: { _ in }, answer: { _ in .error(.value("no calls")) }
        )
        guard case .failed(let failure) = end else {
            Issue.record("Expected a failure, got \(end)")
            return
        }
        #expect(failure.exception == "ValueError")
        #expect(failure.message == "nothing to hear")
        #expect(failure.line == 2)
    }

    /// Python's own idea of the working folder works confined, for code
    /// that resolves a relative path.
    @Test func theWorkingFolderCanBeRead() async throws {
        #expect(try await outcome("import os\nos.getcwd()") == "'allowed'")
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

    /// Forking, and spawning even the interpreter itself, which the
    /// profile lets the helper start as: the commands above are refused
    /// for being outside the installation whether or not forking is.
    @Test func forkingAndSpawningAreRefused() async throws {
        #expect(try await outcome("import os\nos.fork()") != "'allowed'")
        #expect(try await outcome("import os, sys\nos.posix_spawn(sys.executable, [sys.executable, \"-c\", \"pass\"], {})") != "'allowed'")
        #expect(try await outcome("import subprocess, sys\nsubprocess.run([sys.executable, \"-c\", \"pass\"], check=True)") != "'allowed'")
    }

    /// A terminal's tty is the person's to read, and what is typed into
    /// it, passwords too, mustn't reach an expression.
    @Test func aTerminalsTtyCantBeOpened() async throws {
        let main = posix_openpt(O_RDWR | O_NOCTTY)
        #expect(main >= 0)
        defer { close(main) }
        #expect(grantpt(main) == 0 && unlockpt(main) == 0)
        let tty = try #require(ptsname(main).map { String(cString: $0) })
        #expect(try await outcome("open(\"\(tty)\", \"rb\", buffering=0).close()") != "'allowed'")
    }

    @Test func readingTheHomeFolderIsRefused() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(try await outcome("import os\nos.listdir(\"\(home)\")") != "'allowed'")
    }

    @Test func theScriptsHelperIsntConfined() async throws {
        let python = TestPython.interpreter!
        let helper = PythonHelper(interpreter: { PythonInterpreter(executable: python, source: .development) })
        defer { Task { await helper.shutDown() } }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let end = try await helper.run(
            HelperRequest(kind: .line, code: "import os\nisinstance(os.listdir(\"\(home)\"), list)"),
            output: { _ in }, answer: { _ in .error(.value("no calls")) }
        )
        #expect(end == .finished(display: "True"))
    }

    /// Confined code can't write preferences through `cfprefsd`, a way
    /// out the profile's file rules wouldn't cover: no Mach service is
    /// allowed, so the write goes nowhere. The same calls unconfined do
    /// write (tried by hand, code-review-notes.md, F60).
    @Test func preferencesCantBeWrittenThroughCfprefsd() async throws {
        let domain = "com.example.amv-confinement-\(UUID().uuidString)"
        let synchronized = try await run("""
        import ctypes
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFPreferencesSetAppValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        cf.CFPreferencesAppSynchronize.argtypes = [ctypes.c_void_p]
        cf.CFPreferencesAppSynchronize.restype = ctypes.c_bool
        text = lambda t: cf.CFStringCreateWithCString(None, t.encode(), 0x08000100)
        app = text("\(domain)")
        cf.CFPreferencesSetAppValue(text("written"), text("yes"), app)
        cf.CFPreferencesAppSynchronize(app)
        """)
        #expect(synchronized == "False")
        CFPreferencesAppSynchronize(domain as CFString)
        #expect(CFPreferencesCopyAppValue("written" as CFString, domain as CFString) == nil)
        let plist = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/\(domain).plist")
        #expect(!FileManager.default.fileExists(atPath: plist.path))
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
        #expect(profile.contains("(deny default)") && profile.contains("(import \"system.sb\")"))
        // The denials come last, so they win over anything allowed before.
        #expect(profile.hasSuffix("(deny process-fork)\n(deny network*)"))
        #expect(!profile.contains("(allow network") && !profile.contains("(allow process-fork") && !profile.contains("file-write*"))
    }

    /// A Python linked from the home folder's bin gives the home folder
    /// as its installation, which would make all of it readable and
    /// runnable: only the link itself and where it leads are.
    @Test func aPythonInTheHomeFoldersBinDoesntOpenTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let python = URL(filePath: home + "/bin/python3")
        let profile = HelperConfinement.profile(interpreter: python, host: URL(filePath: "/App/Python/amv_host/__main__.py"))
        #expect(!HelperConfinement.installations(of: python).contains(home))
        #expect(!profile.contains("(subpath \"\(home)\")"))
        #expect(profile.contains("(literal \"\(home)/bin/python3\")"))
        #expect(!HelperConfinement.readableFolders(interpreter: python, host: URL(filePath: "/App/Python/amv_host/__main__.py")).contains("/dev"))
    }

    @Test func aFrameworkPythonMayStartAsItsPythonApp() {
        let profile = HelperConfinement.profile(
            interpreter: URL(filePath: "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3"),
            host: URL(filePath: "/App/Python/amv_host/__main__.py")
        )
        #expect(profile.contains("(allow process-exec*\n    (subpath \"/Library/Frameworks/Python.framework/Versions/3.13\")"))
    }
}
