import AppKit
import UniformTypeIdentifiers

/// What the Scripts menu's items do (see docs/python-scripting.md, "A
/// script"): run a script on the project in the front window, asking
/// first for one that came with a project from elsewhere; make one; and
/// run one kept anywhere else.
@MainActor
enum ScriptActions {
    /// How many scripts Run Script File… remembers.
    static let recentCount = 5

    /// Runs one of the project's own scripts, once approved as it is now:
    /// its text and the files beside it, read once (`ScriptSnapshot`), and
    /// that reading is what runs. Approval is of that content, never of
    /// the project, so a script changed since asks again (decision D5).
    static func run(_ script: ScriptFile, in session: ProjectSession) async {
        guard session.projectURL != nil else { return }
        let snapshot: ScriptSnapshot
        do {
            snapshot = try ScriptSnapshot.take(of: script.url)
        } catch {
            showProblem("Couldn't Run \u{201C}\(script.title)\u{201D}", ErrorAdvice.sentence(for: error))
            return
        }
        let approval = CodeApproval.shared
        let code = snapshot.approvalCode
        if !approval.isAllowed(code) {
            switch ask(about: script, withFilesBeside: !snapshot.files.isEmpty) {
            case .run(let remember):
                if remember { approval.allow(code) }
            case .show:
                NSWorkspace.shared.open(script.url)
                return
            case .cancel:
                return
            }
        }
        let imports: URL
        do {
            imports = try snapshot.materialize()
        } catch {
            showProblem("Couldn't Run \u{201C}\(script.title)\u{201D}", ErrorAdvice.sentence(for: error))
            return
        }
        defer { try? FileManager.default.removeItem(at: imports) }
        await run(snapshot.text, at: script.url, importingFrom: imports, named: script.title, in: session)
    }

    /// Runs a script picked with Run Script File…, from wherever it is:
    /// picking it is the person's act, as opening a file is.
    static func runFile(_ url: URL, in session: ProjectSession) async {
        guard let text = read(url) else { return }
        remember(url)
        await run(text, at: url, named: ScriptFile(url: url, text: text).title, in: session)
    }

    /// Asks for a script to run from anywhere.
    static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.pythonScript]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Run"
        panel.message = "Choose a Python script to run on the project in the front window. It can read and change files on this Mac."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// New Script…: asks for a name, makes the file in the project's
    /// `Scripts/` and opens it in the Mac's editor for `.py` files.
    static func newScript(in session: ProjectSession) async {
        guard let package = session.projectURL else { return }
        let alert = NSAlert()
        alert.messageText = "New Script"
        alert.informativeText = "The script is kept in the project's Scripts folder and listed in the Scripts menu under the first line of its docstring."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "Untitled Script"
        field.placeholderString = "Name"
        field.setAccessibilityLabel("Script name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let url = try await ScriptLibrary.makeScript(named: field.stringValue, in: package)
            session.scriptLibrary.reload()
            NSWorkspace.shared.open(url)
        } catch {
            showProblem("Couldn't Make the Script", ErrorAdvice.sentence(for: error))
        }
    }

    /// Show Scripts Folder: the project's `Scripts/` in the Finder, made
    /// first if there is none.
    static func showFolder(of session: ProjectSession) {
        guard let package = session.projectURL else { return }
        let folder = ScriptLibrary.folder(in: package)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// The scripts last run with Run Script File…, newest first, that are
    /// still there.
    static func recentFiles(_ stored: String) -> [URL] {
        let paths = (try? JSONDecoder().decode([String].self, from: Data(stored.utf8))) ?? []
        return paths.map { URL(filePath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Running

    private static func run(
        _ text: String, at url: URL, importingFrom imports: URL? = nil, named name: String, in session: ProjectSession
    ) async {
        let runner = ScriptRunner.shared
        var request = HelperRequest(kind: .script, code: text, path: url)
        request.imports = imports
        runner.transcript.append(.note("Running \u{201C}\(name)\u{201D}\n"))
        switch await runner.run(request, named: name, on: ScriptTarget(session: session)) {
        case .failed(let failure) where !failure.wasStopped:
            // Its traceback is in the console.
            ScriptConsoleWindow.shared.show()
            AccessibilityNotification.Announcement("\u{201C}\(name)\u{201D} stopped with an error. \(failure.summary)").post()
        case .couldNotRun(let reason):
            showProblem("Couldn't Run \u{201C}\(name)\u{201D}", reason)
        case .projectChanged:
            showProblem("\u{201C}\(name)\u{201D} Changed Nothing", "The project changed while it ran, so its changes weren't kept. Run it again.")
        default:
            break
        }
    }

    private enum Answer: Equatable { case run(remember: Bool), show, cancel }

    /// The question for a script not approved as it is now: new, from
    /// elsewhere, or changed since.
    private static func ask(about script: ScriptFile, withFilesBeside: Bool) -> Answer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run \u{201C}\(script.title)\u{201D}?"
        alert.informativeText = approvalText(withFilesBeside: withFilesBeside)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember approval for these scripts"
        alert.suppressionButton?.state = .off
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Show Script")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .run(remember: alert.suppressionButton?.state == .on)
        case .alertSecondButtonReturn: return .show
        default: return .cancel
        }
    }

    /// What the question says: what an unrestricted script can do, what
    /// approving it covers, and what it doesn't.
    static func approvalText(withFilesBeside: Bool) -> String {
        let covered = withFilesBeside
            ? "Approving covers this script and the files in its folder exactly as they are now"
            : "Approving covers this script exactly as it is now"
        return "Scripts aren't restricted: this one can read, change and delete your files and use the network, with your permissions. "
            + "\(covered); if any of it changes, in this app or elsewhere, you're asked again. "
            + "Modules it imports from outside its folder, such as installed packages, aren't checked. "
            + "Run it only if you trust where it came from."
    }

    private static func read(_ url: URL) -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            showProblem("Couldn't Read \u{201C}\(url.lastPathComponent)\u{201D}", ErrorAdvice.sentence(for: error))
            return nil
        }
    }

    private static func remember(_ url: URL) {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: Preferences.recentScriptFiles) ?? "[]"
        var paths = (try? JSONDecoder().decode([String].self, from: Data(stored.utf8))) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        let kept = Array(paths.prefix(recentCount))
        if let data = try? JSONEncoder().encode(kept) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: Preferences.recentScriptFiles)
        }
    }

    private static func showProblem(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
