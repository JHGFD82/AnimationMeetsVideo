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
        // Not /dev: the base profile already gives what Python needs there
        // (null, zero, random, urandom), and all of it let an expression
        // open a Terminal's tty and read what was typed into it.
        let system = [
            "/System", "/usr/lib", "/usr/share", "/Library/Apple", "/private/var/db/dyld", "/private/var/db/timezone",
            "/private/etc",
        ]
        // amv_host/__main__.py → the folder holding amv_host.
        let code = host.deletingLastPathComponent().deletingLastPathComponent()
        let folders = system + installations(of: interpreter) + [code.path, code.resolvingSymlinksInPath().path]
        var seen = Set<String>()
        return folders.filter { seen.insert($0).inserted }
    }

    /// The installations the helper may run code from: the interpreter's,
    /// by the path it was chosen at and the one its links lead to (bin/
    /// python3 → the folder holding bin). A framework build (Homebrew's,
    /// python.org's) starts again as its Python.app, inside its
    /// installation, at once. Never the home folder or a folder holding
    /// it: a `~/bin/python3` linking to Homebrew's made the whole home
    /// folder readable and runnable; its link is allowed by itself
    /// instead (`interpreterFiles`).
    static func installations(of interpreter: URL) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let paths = [interpreter, interpreter.resolvingSymlinksInPath()].map {
            $0.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
        }
        var seen = Set<String>()
        return paths.filter { path in
            let holdsHome = path == "/" || home == path || home.hasPrefix(path.hasSuffix("/") ? path : path + "/")
            return !holdsHome && seen.insert(path).inserted
        }
    }

    /// The interpreter's own file, by the path it was chosen at and the
    /// one its links lead to, which may be outside every installation
    /// allowed.
    static func interpreterFiles(_ interpreter: URL) -> [String] {
        let paths = [interpreter.standardizedFileURL.path, interpreter.resolvingSymlinksInPath().path]
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// The profile, in the sandbox's own language. It starts from Apple's
    /// own base profile for any process (`system.sb`: the system's
    /// libraries and what starting needs), which a profile written path
    /// by path missed, so Python couldn't start. The rules after it win
    /// where they disagree, so the last ones take away what an expression
    /// mustn't have whatever the base allows.
    static func profile(interpreter: URL, host: URL) -> String {
        let files = interpreterFiles(interpreter).map { "    (literal \(quoted($0)))" }
        let readable = (readableFolders(interpreter: interpreter, host: host).map { "    (subpath \(quoted($0)))" } + files)
            .joined(separator: "\n")
        let runnable = (installations(of: interpreter).map { "    (subpath \(quoted($0)))" } + files)
            .joined(separator: "\n")
        return """
        (version 1)
        (deny default)
        (import "system.sb")
        ; Python, and what its installation starts it as: never anything
        ; outside it, and, below, never a second process.
        (allow process-exec*
        \(runnable))
        ; What Python and the system libraries read to start and run.
        (allow file-read*
        \(readable))
        ; Looking a path up isn't reading what is in it.
        (allow file-read-metadata)
        (allow file-write-data
            (literal "/dev/null"))
        (allow sysctl-read)
        (allow signal (target self))
        ; What an expression may never do, whatever is allowed above: start
        ; another process, or reach the network.
        (deny process-fork)
        (deny network*)
        """
    }

    /// A string as the profile language writes one.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
