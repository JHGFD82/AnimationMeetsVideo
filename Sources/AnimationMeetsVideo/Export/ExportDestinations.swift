import Foundation

/// Where exports save, kept apart. Each exporter replaces what is at its
/// destination once it has finished (`ExportFile`), so an export to a
/// place one under way or queued saves to would replace that one's file,
/// and one saved over a media file the project uses would read it while
/// rendering and then replace the person's footage. A WAV Stems export's
/// destination is its folder.
enum ExportDestinations {
    /// The media file of `project` that `url` is, if it is one, so the
    /// export can be refused (code-review-notes.md, F72). Compared with
    /// links resolved and without case, since the file exists.
    static func mediaFile(at url: URL, in project: EditingProject) -> MediaClip? {
        let wanted = resolvedKey(url)
        return project.clips.first { $0.url.map(resolvedKey) == wanted }
    }

    /// Throws when `url` is a media file of `project`.
    static func refuseMediaFile(at url: URL, in project: EditingProject) throws {
        guard let media = mediaFile(at: url, in: project) else { return }
        throw CompositionError.exportFailed(
            "\u{201C}\(url.lastPathComponent)\u{201D} is the file of \u{201C}\(media.name)\u{201D}, which the project uses. Export somewhere else, or under another name."
        )
    }

    private static func resolvedKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }

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
