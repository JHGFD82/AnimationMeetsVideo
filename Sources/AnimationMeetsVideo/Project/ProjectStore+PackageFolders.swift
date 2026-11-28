import Darwin
import Foundation

/// A write into a package found nothing where the package was: it was
/// moved, renamed or deleted since the writer was told where it is.
struct PackageNotFound: LocalizedError, Equatable {
    let packageURL: URL

    var errorDescription: String? {
        "\u{201C}\(packageURL.deletingPathExtension().lastPathComponent)\u{201D} isn\u{2019}t where it was opened from: it may have been moved, renamed or deleted. Nothing was written where it had been."
    }
}

extension ProjectStore {
    /// Makes `folder`, inside `packageURL`, and the folders between them,
    /// one at a time and never the package itself or a folder above it.
    /// Throws `PackageNotFound` when the package isn't there.
    ///
    /// Writing into a package made its folders with intermediate
    /// directories, so a write in the moments after the package was moved,
    /// before the move was noticed, made the package again where it had
    /// been, and a file copied in then lay outside the project
    /// (code-review-notes.md, F123). Made a level at a time, a folder
    /// whose parent has gone fails instead, however late the move comes,
    /// and so does the write that would follow into it. Creating a package
    /// is `preparePackage`'s, and only for a new one.
    ///
    /// A folder not inside `packageURL` is made with intermediate
    /// directories, as before.
    static func makeFolder(_ folder: URL, inPackage packageURL: URL) throws {
        let package = packageURL.standardizedFileURL.pathComponents
        let target = folder.standardizedFileURL.pathComponents
        guard target.count >= package.count, Array(target.prefix(package.count)) == package else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return
        }
        guard target.count > package.count else {
            // The package itself: it must already be there.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { throw PackageNotFound(packageURL: packageURL) }
            return
        }
        var path = packageURL.standardizedFileURL.path
        for component in target.dropFirst(package.count) {
            path = (path as NSString).appendingPathComponent(component)
            guard mkdir(path, 0o777) != 0 else { continue }
            switch errno {
            // Made before, or by another writer just now. Something there
            // that isn't a folder fails the write into it.
            case EEXIST: continue
            // A folder above it, the package itself among them, isn't there.
            case ENOENT: throw PackageNotFound(packageURL: packageURL)
            case let code: throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
    }
}
