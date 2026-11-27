import CryptoKit
import Foundation

/// The exact code one of a project's scripts runs with
/// (docs/python-scripting.md, "Safety"): its text and every file of its
/// folder, read once. Approval covers this, by `approvalCode`; and this is
/// what runs, since its files are copied to a private folder the helper
/// imports from (`materialize`), so a file changed between the approval
/// and the import isn't the one imported.
///
/// What it can't bound: modules imported from outside the folder (the
/// standard library and installed packages), and files a script opens and
/// runs itself. The prompt says so.
struct ScriptSnapshot: Sendable {
    struct File: Sendable, Equatable {
        /// Its path in the script's folder, as "/util.py" or "/lib/csv.py".
        var path: String
        var data: Data
    }

    enum Problem: Error, LocalizedError, Equatable {
        /// A link in the script's folder, which could point anywhere and
        /// be pointed elsewhere after approval.
        case link(String)
        /// More than `mostFiles` files or `mostBytes` bytes beside it.
        case tooLarge
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .link(let name):
                "\u{201C}\(name)\u{201D} in the script's folder is a link, which could lead to code no one approved. Replace it with the file itself."
            case .tooLarge:
                "The script's folder holds more than \(ScriptSnapshot.mostFiles) files or \(ScriptSnapshot.mostBytes >> 20) MB, more than is checked before a run. Keep only the script and what it imports there."
            case .unreadable(let name):
                "\u{201C}\(name)\u{201D} in the script's folder can't be read."
            }
        }
    }

    static let mostFiles = 2_000
    static let mostBytes = 64 << 20

    /// The script as it was read.
    let script: URL
    let text: String
    /// Every other file of its folder and the folders in it, but
    /// `__pycache__` (compiled modules Python could run in place of their
    /// source; the helper never writes them, `-B`) and `.DS_Store`.
    let files: [File]

    /// Reads the script at `url` and everything beside it.
    static func take(of url: URL) throws -> ScriptSnapshot {
        let url = url.standardizedFileURL
        let folder = url.deletingLastPathComponent()
        for checked in [folder, url] where (try? checked.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw Problem.link(checked.lastPathComponent)
        }
        guard let scriptData = try? Data(contentsOf: url), let text = String(data: scriptData, encoding: .utf8) else {
            throw Problem.unreadable(url.lastPathComponent)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            throw Problem.unreadable(folder.lastPathComponent)
        }
        var files: [File] = []
        var bytes = scriptData.count
        for case let file as URL in walk {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let path = String(file.standardizedFileURL.path.dropFirst(folder.path.count))
            if values?.isSymbolicLink == true { throw Problem.link(String(path.dropFirst())) }
            if values?.isDirectory == true {
                if file.lastPathComponent == "__pycache__" { walk.skipDescendants() }
                continue
            }
            guard file.standardizedFileURL != url, file.lastPathComponent != ".DS_Store" else { continue }
            // Neither a file nor a folder: a socket or pipe, run as nothing.
            guard values?.isRegularFile == true else { throw Problem.unreadable(String(path.dropFirst())) }
            guard let data = try? Data(contentsOf: file) else { throw Problem.unreadable(String(path.dropFirst())) }
            bytes += data.count
            files.append(File(path: path, data: data))
            if files.count > mostFiles || bytes > mostBytes { throw Problem.tooLarge }
        }
        files.sort { $0.path < $1.path }
        return ScriptSnapshot(script: url, text: text, files: files)
    }

    /// What approving it approves: its text, and each other file by path
    /// and SHA-256, so changing, adding or removing any asks again. A
    /// script alone in its folder is approved by its text alone.
    var approvalCode: String {
        guard !files.isEmpty else { return text }
        let lines = files.map { file in
            "\(file.path) " + SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()
        }
        return text + "\n\0beside it:\n" + lines.joined(separator: "\n")
    }

    /// Writes the files read, and the script, to a new folder of the
    /// person's own, for the helper to import from; the caller removes
    /// it after the run.
    func materialize(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = parent.appending(path: "amv-script-\(UUID().uuidString)", directoryHint: .isDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for file in files + [File(path: "/" + script.lastPathComponent, data: Data(text.utf8))] {
                let destination = folder.appending(path: String(file.path.dropFirst()))
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: destination, options: .withoutOverwriting)
            }
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
        return folder
    }
}
