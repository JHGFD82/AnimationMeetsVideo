import CoreServices
import Foundation

/// Watches a folder of effect packages and says which packages changed in
/// it: edited, added, removed or renamed. FSEvents sees a change anywhere
/// inside a package, such as an editor saving kernel.metal by putting a new
/// file in its place, which a source on the folder itself wouldn't. Events
/// are gathered for `latency` before they are delivered, so a save that
/// writes several files reads the package once.
final class EffectFolderWatcher {
    private let folder: URL
    private let changed: @MainActor ([URL]) -> Void
    private var stream: FSEventStreamRef?

    /// Starts watching `folder`, made first if there is none yet, and
    /// calls `changed` on the main thread with the packages changed.
    init(folder: URL, latency: TimeInterval = 0.3, changed: @escaping @MainActor ([URL]) -> Void) {
        self.folder = folder
        self.changed = changed
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<EffectFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let packages = watcher.packages(changedAt: paths)
            guard !packages.isEmpty else { return }
            let changed = watcher.changed
            MainActor.assumeIsolated { changed(packages) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else {
            NSLog("The Effects folder can't be watched; a package changed in it is read at the next launch.")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// The packages directly in the folder that `paths` are in or are,
    /// each once, in order; every package in it for the folder itself,
    /// which FSEvents reports when it lost track of what changed.
    func packages(changedAt paths: [String]) -> [URL] {
        // FSEvents reports paths with links resolved (/private/var, not /var).
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var names: [String] = []
        for path in paths {
            let components = URL(filePath: path).standardizedFileURL.pathComponents
            guard components.starts(with: base) else { continue }
            if components.count == base.count {
                let listed = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                names += listed.filter { $0.hasSuffix(".\(EffectPackage.fileExtension)") && !$0.hasPrefix(".") }.sorted()
            } else {
                let name = components[base.count]
                if name.hasSuffix(".\(EffectPackage.fileExtension)"), !name.hasPrefix(".") { names.append(name) }
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.map { folder.appending(path: $0, directoryHint: .isDirectory) }
    }
}
