import Foundation

/// Where exports save, kept apart. Each exporter deletes what is at its
/// destination before writing (`CompositionExporter.export`,
/// `AudioExport.exportMix`, each stem in `AudioExport.exportStems`), so
/// an export to a place one under way or queued saves to would delete
/// that one's file. A WAV Stems export's destination is its folder.
enum ExportDestinations {
    /// The destination in `taken` that is the same place as `url`, or nil.
    /// Paths are compared without case, as the Mac's volumes are by
    /// default. Symlinks aren't resolved: `resolvingSymlinksInPath` treats
    /// a file that exists differently from one not written yet.
    static func conflict(for url: URL, among taken: [URL]) -> URL? {
        let wanted = key(url)
        return taken.first { key($0) == wanted }
    }

    /// `base`, or "`base` 2", "`base` 3" and on: the first that, with
    /// `fileExtension` (nil for a folder), is no name in `taken`. The
    /// save panel's folder isn't known before it opens, so a name taken
    /// in any folder is skipped.
    static func freeName(_ base: String, fileExtension: String?, avoiding taken: [URL]) -> String {
        let names = Set(taken.map { $0.lastPathComponent.lowercased() })
        func file(_ name: String) -> String {
            (fileExtension.map { "\(name).\($0)" } ?? name).lowercased()
        }
        var candidate = base
        var number = 2
        while names.contains(file(candidate)) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }
}
