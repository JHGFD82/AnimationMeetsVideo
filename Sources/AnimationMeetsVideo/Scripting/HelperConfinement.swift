import Foundation

/// The sandbox the expressions' helper runs in (see
/// docs/python-scripting.md, "Safety"): no network, no writing files, no
/// starting processes, and no reading beyond the system, the interpreter
/// and the helper's own code. An expression is arithmetic; it needs none
/// of them, and allowing it to run shouldn't mean trusting it with the
/// person's files.
///
/// The helper is started through `sandbox-exec`, which Apple marks
/// deprecated and which still works and has no replacement for this; if
/// it goes, the helper becomes a signed tool with App Sandbox
/// entitlements. Scripts aren't confined: reading a spreadsheet or
/// writing a file is the point of them.
enum HelperConfinement {
    static let sandboxExec = URL(filePath: "/usr/bin/sandbox-exec")

    /// Whether the system can confine the helper at all.
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: sandboxExec.path)
    }

    /// The command that starts `interpreter` on `host` confined: the
    /// executable and its arguments.
    static func command(interpreter: URL, host: URL) -> (executable: URL, arguments: [String]) {
        let profile = profile(interpreter: interpreter, host: host)
        return (sandboxExec, ["-p", profile, interpreter.path] + PythonRuntime.helperArguments(host: host))
    }

    /// The folders the helper may read: the system's, the interpreter's
    /// installation (by the path it was chosen at and the one its links
    /// lead to, as a Homebrew or virtual environment's Python links into
    /// another), and the helper's own code.
    static func readableFolders(interpreter: URL, host: URL) -> [String] {
        let system = [
            "/System", "/usr/lib", "/usr/share", "/Library/Apple", "/private/var/db/dyld", "/private/var/db/timezone",
            "/private/etc", "/dev",
        ]
        let resolved = interpreter.resolvingSymlinksInPath()
        // bin/python3 → the installation it is in.
        let prefixes = [interpreter, resolved].map { $0.deletingLastPathComponent().deletingLastPathComponent().path }
        // amv_host/__main__.py → the folder holding amv_host.
        let code = host.deletingLastPathComponent().deletingLastPathComponent()
        let folders = system + prefixes + [code.path, code.resolvingSymlinksInPath().path]
        var seen = Set<String>()
        return folders.filter { seen.insert($0).inserted }
    }

    /// The profile, in the sandbox's own language.
    static func profile(interpreter: URL, host: URL) -> String {
        let readable = readableFolders(interpreter: interpreter, host: host)
            .map { "    (subpath \(quoted($0)))" }
            .joined(separator: "\n")
        let executables = Set([interpreter.path, interpreter.resolvingSymlinksInPath().path])
            .sorted()
            .map { "    (literal \(quoted($0)))" }
            .joined(separator: "\n")
        return """
        (version 1)
        (deny default)
        ; Python itself, which sandbox-exec starts, and nothing after it:
        ; no process-fork, so no subprocess, os.system or multiprocessing.
        (allow process-exec
        \(executables))
        ; What Python and the system libraries read to start and run.
        (allow file-read*
        \(readable))
        ; Looking a path up isn't reading what is in it.
        (allow file-read-metadata)
        ; Its own pipes and /dev/null; no file anywhere else.
        (allow file-write-data
            (literal "/dev/null"))
        (allow sysctl-read)
        (allow signal (target self))
        ; No network: nothing allows network*, so it is denied by default.
        """
    }

    /// A string as the profile language writes one.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
