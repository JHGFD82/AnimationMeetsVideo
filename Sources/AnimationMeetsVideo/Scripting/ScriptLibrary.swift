import Foundation
import Observation

/// A script file, as the Scripts menu lists it.
struct ScriptFile: Identifiable, Equatable, Sendable {
    var url: URL
    /// The first line of its docstring, or its file name.
    var title: String

    var id: URL { url }

    /// Reads a script's title from its text.
    init(url: URL, text: String?) {
        self.url = url
        title = text.flatMap(Self.docstringTitle) ?? url.deletingPathExtension().lastPathComponent
    }

    /// The first line of a module's docstring: the string the file opens
    /// with, after any comments (a `#!` line, an encoding) and blank
    /// lines. Nil when it opens with anything else, or the line is blank.
    static func docstringTitle(of text: String) -> String? {
        var rest = Substring(text)
        while true {
            let trimmed = rest.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
            if trimmed.hasPrefix("#") {
                rest = trimmed.drop { $0 != "\n" }
                continue
            }
            rest = trimmed
            break
        }
        // A prefix such as r or u, then three quotes or one.
        let prefixed = rest.prefix { "rRuU".contains($0) }
        guard prefixed.count <= 1 else { return nil }
        rest = rest.dropFirst(prefixed.count)
        let quote: String
        if rest.hasPrefix("\"\"\"") { quote = "\"\"\"" } else if rest.hasPrefix("'''") { quote = "'''" }
        else if rest.hasPrefix("\"") { quote = "\"" } else if rest.hasPrefix("'") { quote = "'" } else { return nil }
        rest = rest.dropFirst(quote.count)
        guard let end = rest.range(of: quote) else { return nil }
        let body = rest[..<end.lowerBound]
        let first = body.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return first
    }
}

/// A project's scripts: the `.py` files in its package's `Scripts/`
/// folder, beside `project.json` and `Media/`, so they are kept, copied
/// and sent with the project they work on (see docs/python-scripting.md,
/// "Where scripts live"). The folder is the person's work, never deleted
/// by the app, and watched while the project is open, so a file added or
/// changed in it is listed without reopening the project.
@MainActor
@Observable
final class ScriptLibrary {
    nonisolated static let folderName = ProjectStore.scriptsFolderName
    nonisolated static let fileExtension = "py"

    /// The scripts, by title.
    private(set) var scripts: [ScriptFile] = []
    private(set) var folder: URL?
    @ObservationIgnored private var watcher: EffectFolderWatcher?

    nonisolated static func folder(in packageURL: URL) -> URL {
        packageURL.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Lists and watches the scripts of the package at `packageURL`, or
    /// stops for nil.
    func watch(package packageURL: URL?) {
        let folder = packageURL.map(Self.folder(in:))
        guard folder != self.folder else { return }
        self.folder = folder
        watcher = nil
        scripts = []
        guard let folder else { return }
        // Made if there is none yet: the watcher needs a folder to watch.
        watcher = EffectFolderWatcher(folder: folder, itemExtension: Self.fileExtension) { [weak self] _ in self?.reload() }
        reload()
    }

    /// Lists the folder again.
    func reload() {
        guard let folder else { return }
        scripts = Self.list(folder)
    }

    /// The `.py` files directly in `folder`, by title.
    nonisolated static func list(_ folder: URL) -> [ScriptFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasSuffix(".\(fileExtension)") && !$0.hasPrefix(".") }
            .map { name in
                let url = folder.appending(path: name, directoryHint: .notDirectory)
                return ScriptFile(url: url, text: try? String(contentsOf: url, encoding: .utf8))
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The text New Script… starts a file with.
    static func template(titled title: String) -> String {
        """
        \"\"\"\(title)\"\"\"
        import amv

        # The project in the front window, as one undo step: a script that
        # raises changes nothing. See docs/python-scripting.md.
        for clip in amv.selection:
            print(clip.name, clip.start, clip.end)

        """
    }

    /// Makes a new script in the package's `Scripts/`, through the
    /// package's queue of writes, and gives its file.
    static func makeScript(named name: String, in packageURL: URL) async throws -> URL {
        let folder = folder(in: packageURL)
        let base = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let stem = base.isEmpty ? "Untitled" : base
        let text = template(titled: stem)
        let fileExtension = fileExtension
        return try await PackageCoordinator.shared.run(on: [packageURL]) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var url = folder.appending(path: "\(stem).\(fileExtension)")
            var number = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appending(path: "\(stem) \(number).\(fileExtension)")
                number += 1
            }
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            return url
        }
    }
}
