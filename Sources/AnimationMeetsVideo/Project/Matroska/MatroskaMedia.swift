import Foundation
import Synchronization

/// The reference movies of a project's Matroska files (see
/// docs/matroska.md): made when a file is imported, the project is opened
/// or saved, and kept in the package's `Cache/References/`, since a movie
/// is only an index that can always be made again. A project not yet saved
/// keeps them in a temporary folder until it is.
///
/// Each file's movie is noted here once made, so that everything that
/// opens the file opens its movie instead (`MediaFile`).
enum MatroskaMedia {
    static let folderName = "References"

    /// Where `packageURL`'s reference movies go; for nil, a project not yet
    /// saved, a temporary folder.
    static func folder(in packageURL: URL?) -> URL {
        guard let packageURL else { return unsavedFolder }
        return packageURL
            .appending(path: ProjectStore.cacheFolderName, directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
    }

    static var unsavedFolder: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "com.jhgfd.animationmeetsvideo/\(folderName)", directoryHint: .isDirectory)
    }

    /// The movie made for each Matroska file, by the file's path.
    private static let movies = Mutex<[String: URL]>([:])

    /// Whether the file is Matroska (or WebM), by its first bytes rather
    /// than its name.
    static func isMatroska(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x1A, 0x45, 0xDF, 0xA3])
    }

    /// The reference movie made for the Matroska file at `url`, or nil when
    /// none was. A file that changed since its movie was made gets a new
    /// one, in the same folder, since the old one points at bytes that
    /// have moved.
    static func referenceMovie(for url: URL) -> URL? {
        guard let movie = movies.withLock({ $0[key(url)] }) else { return nil }
        guard let name = movieName(for: url) else { return movie }
        if movie.lastPathComponent == name, FileManager.default.fileExists(atPath: movie.path) { return movie }
        return (try? prepare(url, in: movie.deletingLastPathComponent())) ?? movie
    }

    /// Makes the reference movie for the Matroska file at `url` in `folder`
    /// unless it is there already, notes it as the file's, and returns it.
    /// `progress` is told how far the making has got, 0...1.
    @discardableResult
    static func prepare(_ url: URL, in folder: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        guard let name = movieName(for: url) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: url])
        }
        let movie = folder.appending(path: name)
        if !FileManager.default.fileExists(atPath: movie.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Written beside it and moved into place, so a movie half made
            // is never used.
            let partial = folder.appending(path: "\(UUID().uuidString).partial.mov")
            defer { try? FileManager.default.removeItem(at: partial) }
            // Reading the file is most of the time for a file not yet in
            // memory; writing the movie the rest.
            let index = try MatroskaIndex.read(url) { progress($0 * readShare) }
            try MatroskaReferenceMovie.write(index: index, source: url, to: partial) {
                progress(readShare + $0 * (1 - readShare))
            }
            do {
                try FileManager.default.moveItem(at: partial, to: movie)
            } catch where FileManager.default.fileExists(atPath: movie.path) {
                // Made at the same time by another import of the same file.
            }
        }
        movies.withLock { $0[key(url)] = movie }
        return movie
    }

    /// How much of `prepare`'s progress is reading the file (3.4 s of 4.6 s
    /// for a 16.6 GB, 82-minute film).
    private static let readShare = 0.75

    /// The movie's file name: a hash of the Matroska file's path, size and
    /// modification date, so a moved or changed file gets a new movie.
    static func movieName(for url: URL) -> String? {
        FileStamp.cacheDigest(for: url).map { "\($0).mov" }
    }

    /// Deletes the package's reference movies other than those named in
    /// `keeping`, left by files since moved, changed or removed.
    static func removeUnused(in packageURL: URL, keeping: Set<String>) {
        let folder = folder(in: packageURL)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where !keeping.contains(name) && !name.hasSuffix(".partial.mov") {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
