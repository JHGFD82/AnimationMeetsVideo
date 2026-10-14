import CoreMedia
import Foundation

/// A stretch of a timeline drawn the same way throughout: the unit the
/// render cache stores. Planned by `CompositionExporter` on every build.
struct RenderSegment: Equatable, @unchecked Sendable {
    /// Where it sits in the timeline.
    var range: CMTimeRange
    /// Names its render in the cache; empty when it needs none.
    var key: String
    /// False for a single layer drawn the same way throughout, which plays
    /// straight from its file, and for gaps.
    var needsRender: Bool
    /// The clips of the built timeline drawn in it.
    var clipIDs: Set<UUID>

    /// The longest a rendered segment gets, so a render stopped by an edit
    /// loses little and finished parts play as soon as they're done.
    static let maxFrames = 96
    /// Bumped when drawing changes in a way the key doesn't capture, so old
    /// renders stop matching.
    static let formatVersion = 1
}

/// Rendered segments in a package's `Cache/Renders/` folder, one ProRes
/// movie per key. Anything here can be deleted at any time.
struct RenderCache: Sendable {
    let folder: URL

    static let folderName = "Renders"
    /// How much the renders may take before the least recently used go.
    static let defaultLimit: Int64 = 20 * 1024 * 1024 * 1024

    init(packageURL: URL) {
        folder = packageURL
            .appending(path: ProjectStore.cacheFolderName, directoryHint: .isDirectory)
            .appending(path: Self.folderName, directoryHint: .isDirectory)
    }

    func url(for key: String) -> URL {
        folder.appending(path: "\(key).mov")
    }

    /// The finished render for `key`, if there is one.
    func file(for key: String) -> URL? {
        let url = url(for: key)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Where a render in progress is written; renamed into place when done,
    /// so a file under its key is always complete.
    func partialURL(for key: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "\(key).partial.mov")
    }

    func finish(_ key: String) throws {
        let partial = folder.appending(path: "\(key).partial.mov")
        let final = url(for: key)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: partial, to: final)
    }

    /// Records that a render was played, which keeps it from being evicted
    /// before ones that weren't.
    func markUsed(_ key: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url(for: key).path)
    }

    /// Deletes the least recently used renders until the rest fit in
    /// `limit`, never one in `keeping`. Leftover partial files go too.
    func evict(toFit limit: Int64 = defaultLimit, keeping: Set<String> = []) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, key: String, size: Int64, used: Date)] = []
        for url in urls where url.pathExtension == "mov" {
            let name = url.deletingPathExtension().lastPathComponent
            guard !name.hasSuffix(".partial") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            entries.append((url, name, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast))
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.used < $1.used }) where total > limit {
            guard !keeping.contains(entry.key) else { continue }
            if (try? fileManager.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }

    /// Deletes partial renders left by a render that never finished.
    func removePartials(except active: String? = nil) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".partial.mov") && name != active.map({ "\($0).partial.mov" }) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}
