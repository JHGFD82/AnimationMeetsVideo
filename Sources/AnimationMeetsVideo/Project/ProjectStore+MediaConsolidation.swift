import CoreMedia
import Foundation

extension ProjectStore {
    /// Media that saving into `packageURL` would copy in: anything with a file
    /// outside the package, or with `sourcePackageURL` (Save As) only what is
    /// inside that package. `preparePackage` must have run first so the
    /// package's volume can be compared.
    static func mediaToCopy(in project: EditingProject, into packageURL: URL, from sourcePackageURL: URL? = nil) -> [MediaCopyCandidate] {
        project.clips.compactMap { clip in
            guard let url = clip.url, !isInside(url, package: packageURL),
                  sourcePackageURL.map({ isInside(url, package: $0) }) ?? true,
                  FileManager.default.fileExists(atPath: url.path)
            else {
                return nil
            }
            return MediaCopyCandidate(
                clipID: clip.id, sourceURL: url, byteCount: fileSize(of: url),
                isClone: copyIsClone(of: url, into: packageURL)
            )
        }
    }

    static func fileSize(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// True when copying `url` into the package makes an APFS clone, which
    /// is instant and uses no extra disk space.
    static func copyIsClone(of url: URL, into packageURL: URL) -> Bool {
        let packageVolume = volumeInfo(for: packageURL)
        let sourceVolume = volumeInfo(for: url)
        return packageVolume.supportsCloning
            && sourceVolume.identifier != nil
            && sourceVolume.identifier?.isEqual(packageVolume.identifier) == true
    }

    /// An asset ID whose reference data in the package describes a file like
    /// `url` (same size and modification date) and that no asset in `inUse`
    /// has: one imported before and then removed, or never saved into
    /// `project.json`. Importing the file under that ID reuses its analysis.
    static func reusableAssetID(for url: URL, in packageURL: URL, excluding inUse: Set<UUID>) -> UUID? {
        guard let stamp = FileStamp(url: url) else { return nil }
        let folder = packageURL.appending(path: referenceFolderName, directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.sorted() {
            guard let id = UUID(uuidString: name), !inUse.contains(id),
                  let metadata = readReference(for: id, in: packageURL)?.metadata,
                  metadata.byteCount == stamp.byteCount,
                  let captured = metadata.modified, let modified = stamp.modified, abs(captured - modified) < 0.001
            else {
                continue
            }
            return id
        }
        return nil
    }

    /// A file in `Media/` that is a copy of `url` (same size and modification
    /// date, which copying keeps) and whose path isn't in `usedPaths`, so it
    /// can be imported again instead of copying the file once more.
    static func existingCopy(of url: URL, in packageURL: URL, excluding usedPaths: Set<String>) -> URL? {
        guard let stamp = FileStamp(url: url) else { return nil }
        let folder = packageURL.appending(path: mediaFolderName, directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.sorted() {
            let candidate = folder.appending(path: name)
            let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
            guard !usedPaths.contains(path), FileStamp(url: candidate) == stamp else { continue }
            return candidate
        }
        return nil
    }

    /// Copies a file into the package's `Media/` folder, next to any file of
    /// the same name rather than over it, and returns the copy. A file
    /// already inside the package is returned as it is.
    static func copyIntoPackage(_ url: URL, packageURL: URL) throws -> URL {
        guard !isInside(url, package: packageURL) else { return url }
        let mediaFolder = packageURL.appending(path: mediaFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        let destination = uniqueDestination(for: url.lastPathComponent, in: mediaFolder)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private static func volumeInfo(for url: URL) -> (identifier: (any NSObjectProtocol)?, supportsCloning: Bool) {
        let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey, .volumeSupportsFileCloningKey])
        return (values?.volumeIdentifier, values?.volumeSupportsFileCloning ?? false)
    }

    static func isInside(_ url: URL, package packageURL: URL) -> Bool {
        let packagePath = packageURL.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(packagePath + "/")
    }

    private static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = folder.appending(path: name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appending(path: numbered)
            counter += 1
        }
        return candidate
    }
}
