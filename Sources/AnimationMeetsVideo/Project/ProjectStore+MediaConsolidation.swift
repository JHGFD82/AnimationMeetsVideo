import CoreMedia
import Foundation

extension ProjectStore {
    /// Media that saving into `packageURL` would copy in: anything with a file
    /// outside the package, or with `sourcePackageURL` (Save As) only what is
    /// inside that package. The package needn't exist yet: its volume is
    /// the nearest existing folder's above it.
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
        try makeFolder(mediaFolder, inPackage: packageURL)
        let destination = uniqueDestination(for: url.lastPathComponent, in: mediaFolder)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// The volume `url` is on, or would be on once made: that of the
    /// nearest of it and the folders above it that exists.
    private static func volumeInfo(for url: URL) -> (identifier: (any NSObjectProtocol)?, supportsCloning: Bool) {
        var existing = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            existing = existing.deletingLastPathComponent()
        }
        let values = try? existing.resourceValues(forKeys: [.volumeIdentifierKey, .volumeSupportsFileCloningKey])
        return (values?.volumeIdentifier, values?.volumeSupportsFileCloning ?? false)
    }

    static func isInside(_ url: URL, package packageURL: URL) -> Bool {
        let packagePath = packageURL.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(packagePath + "/")
    }

    /// `url` at the same place inside `newPackage` as it had inside
    /// `oldPackage`, for a package that was moved; nil for a file outside
    /// it. The old place no longer exists, so links are resolved through the
    /// nearest folder above it that does.
    static func relocated(_ url: URL, from oldPackage: URL, to newPackage: URL) -> URL? {
        let old = resolvedPath(oldPackage)
        let path = resolvedPath(url)
        guard path.hasPrefix(old + "/") else { return nil }
        return newPackage.appending(path: String(path.dropFirst(old.count + 1)))
    }

    /// The path of `url` with links resolved as far as it exists.
    private static func resolvedPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return rest.reduce(existing.resolvingSymlinksInPath().path) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// Whether `url` is in a Trash, the person's or a volume's.
    static func isInTrash(_ url: URL) -> Bool {
        var relationship = FileManager.URLRelationship.other
        guard (try? FileManager.default.getRelationship(&relationship, of: .trashDirectory, in: .allDomainsMask, toItemAt: url)) != nil
        else { return false }
        return relationship == .contains
    }

    static func uniqueDestination(for name: String, in folder: URL) -> URL {
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
