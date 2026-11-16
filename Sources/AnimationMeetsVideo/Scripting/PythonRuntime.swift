import Foundation

/// A Python the app can run its helper on.
struct PythonInterpreter: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// The CPython in the app bundle, `Contents/Resources/Python`.
        case builtIn
        /// One the person chose in Settings > Scripting.
        case chosen
        /// The one `AMV_PYTHON` names, in development (`swift test`).
        case development
    }

    var executable: URL
    var source: Source
}

/// Finding the interpreter and the helper's own code (see
/// docs/python-scripting.md, "Which Python").
///
/// The built-in one is a relocatable CPython that `scripts/build-app.sh`
/// puts in the bundle (`scripts/fetch-python.sh` fetches it). Settings can
/// point at another, 3.11 or later, so the person's own packages can be
/// imported. Built by SwiftPM there is no bundle, and the interpreter is
/// the one named by `AMV_PYTHON`; without it, nothing that needs Python
/// runs. macOS's own `/usr/bin/python3` is a stub that offers to install
/// the developer tools, so it is never used.
enum PythonRuntime {
    /// The oldest Python the helper runs on: it uses `-P` and nothing of
    /// the standard library newer than that.
    static let oldestVersion = PythonVersion(major: 3, minor: 11, patch: 0)

    /// The interpreter to use: the one chosen in Settings while it is
    /// there, else the built-in one, else `AMV_PYTHON`'s.
    static func interpreter(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        builtIn: URL? = builtInInterpreter
    ) -> PythonInterpreter? {
        if let path = defaults.string(forKey: Preferences.pythonInterpreter), !path.isEmpty, isExecutable(path) {
            return PythonInterpreter(executable: URL(filePath: path), source: .chosen)
        }
        if let builtIn, isExecutable(builtIn.path) {
            return PythonInterpreter(executable: builtIn, source: .builtIn)
        }
        if let path = environment["AMV_PYTHON"], !path.isEmpty, isExecutable(path) {
            return PythonInterpreter(executable: URL(filePath: path), source: .development)
        }
        return nil
    }

    /// The bundle's CPython: `Contents/Resources/Python/bin/python3`.
    static var builtInInterpreter: URL? {
        guard Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL else { return nil }
        return resources.appending(path: "Python/bin/python3")
    }

    /// The helper's entry point, `amv_host/__main__.py`, in the resource
    /// bundle: in Contents/Resources in the app, beside the executable as
    /// SwiftPM builds it.
    static var hostScript: URL? {
        let name = "AnimationMeetsVideo_AnimationMeetsVideo.bundle"
        let folder: URL?
        if let resources = Bundle.main.resourceURL, let bundle = Bundle(url: resources.appending(path: name)) {
            folder = bundle.url(forResource: "Python", withExtension: nil)
        } else {
            folder = Bundle.module.url(forResource: "Python", withExtension: nil)
        }
        return folder?.appending(path: "amv_host/__main__.py")
    }

    /// How the helper is started: environment variables ignored (`-E`),
    /// nothing put on the import path for the working directory (`-P`),
    /// no `.pyc` written into the bundle, whose signature it would break
    /// (`-B`), and text in UTF-8 whatever the locale.
    static func helperArguments(host: URL) -> [String] {
        ["-E", "-P", "-B", "-X", "utf8", host.path]
    }

    /// The interpreter's version, asked of it; nil when it doesn't run or
    /// doesn't answer within a few seconds.
    static func version(of interpreter: URL) async -> PythonVersion? {
        let process = Process()
        process.executableURL = interpreter
        process.arguments = ["-E", "-c", "import sys; print('%d.%d.%d' % sys.version_info[:3])"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return await withCheckedContinuation { (continuation: CheckedContinuation<PythonVersion?, Never>) in
            process.terminationHandler = { ended in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: ended.terminationStatus == 0 ? text.flatMap(PythonVersion.init) : nil)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                return continuation.resume(returning: nil)
            }
            // One that hangs is ended, which answers nil above.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && !isFolder.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

/// A Python version, such as 3.14.0.
struct PythonVersion: Comparable, Sendable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// "3.14.0"; a missing patch is 0.
    init?(_ text: String) {
        let parts = text.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.init(major: parts[0]!, minor: parts[1]!, patch: parts.count == 3 ? parts[2]! : 0)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// Whether the helper runs on it.
    var isSupported: Bool { self >= PythonRuntime.oldestVersion }
}
