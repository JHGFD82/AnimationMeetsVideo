import Foundation

/// Exports are written beside where they go and put there only once
/// finished, so an export that fails or is stopped leaves what was there
/// before, a file the save panel's Replace confirmed, as it was.
enum ExportFile {
    /// A hidden name beside `url` to write to, keeping its extension so the
    /// writer picks the same file type.
    static func partial(for url: URL) -> URL {
        let name = ".\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).partial"
        let file = url.pathExtension.isEmpty ? name : "\(name).\(url.pathExtension)"
        return url.deletingLastPathComponent().appending(path: file)
    }

    /// Puts the finished `partial` at `url`, replacing a file already there.
    static func finish(_ partial: URL, at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: url)
        }
    }
}
