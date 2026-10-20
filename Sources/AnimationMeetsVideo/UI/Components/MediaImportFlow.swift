import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Bringing files into a project's library, the same way whether they
/// were chosen with Import… or dragged in from the Finder: copied into
/// the package's `Media/` folder first when the project copies imports.
@MainActor
enum MediaImportFlow {
    /// What can be imported: movies, sound and still images.
    static let contentTypes: [UTType] = [.movie, .audio, .image]

    /// The files among `urls` that can be imported.
    static func importable(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return contentTypes.contains { type.conforms(to: $0) }
        }
    }

    /// Which of `urls` to copy into the package: none when this import
    /// references them in place, otherwise all, after asking about any
    /// that would use real disk space. Nil to cancel the import.
    static func filesToCopy(_ urls: [URL], copy: Bool, packageURL: URL?) -> Set<URL>? {
        guard copy, let packageURL else { return [] }
        let clones = urls.filter { ProjectStore.copyIsClone(of: $0, into: packageURL) }
        let heavy = urls.filter { !clones.contains($0) }
        guard !heavy.isEmpty else { return Set(urls) }
        let total = heavy.reduce(Int64(0)) { $0 + ProjectStore.fileSize(of: $1) }
        switch MediaCopyPrompt.ask(fileCount: heavy.count, byteCount: total) {
        case .copy: return Set(urls)
        case .referenceInPlace: return Set(clones)
        case nil: return nil
        }
    }

    /// Imports `urls` into the library, adding each to `project` as it is
    /// read, and returns those added, in order. A file that can't be read
    /// is reported to `onError` and skipped.
    ///
    /// A file imported before (and since removed, or never saved) comes
    /// back under its old ID, so its analysis is reused, and its earlier
    /// copy in `Media/` is used instead of copying again.
    static func importFiles(
        _ urls: [URL], copying: Set<URL>, packageURL: URL?, project: Binding<EditingProject>, onError: (String) -> Void
    ) async -> [MediaClip] {
        var claimedIDs = Set(project.wrappedValue.clips.map(\.id))
        var usedPaths = Set(project.wrappedValue.clips.compactMap { $0.url?.standardizedFileURL.resolvingSymlinksInPath().path })
        var imported: [MediaClip] = []
        for url in urls {
            var madeCopy: URL?
            do {
                var source = url
                if copying.contains(url), let packageURL {
                    if let existing = ProjectStore.existingCopy(of: url, in: packageURL, excluding: usedPaths) {
                        source = existing
                    } else {
                        madeCopy = try await PackageCoordinator.shared.run(on: [packageURL]) {
                            try ProjectStore.copyIntoPackage(url, packageURL: packageURL)
                        }
                        source = madeCopy ?? url
                    }
                }
                var clip = try await MediaImporter.importClip(at: source, packageURL: packageURL)
                // A copy may be numbered to avoid a name already in Media/.
                clip.name = url.deletingPathExtension().lastPathComponent
                if let packageURL, let earlier = ProjectStore.reusableAssetID(for: source, in: packageURL, excluding: claimedIDs) {
                    clip.id = earlier
                }
                claimedIDs.insert(clip.id)
                usedPaths.insert(source.standardizedFileURL.resolvingSymlinksInPath().path)
                project.wrappedValue.addMedia(clip)
                imported.append(clip)
            } catch {
                if let madeCopy { try? FileManager.default.removeItem(at: madeCopy) }
                onError("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return imported
    }

    /// Imports files dragged in from the Finder, copying them when the
    /// project copies imports (after asking, as Import… does, about any
    /// that would use real disk space). Nil when nothing could be imported
    /// or the copy was cancelled.
    static func importDropped(
        _ urls: [URL], packageURL: URL?, project: Binding<EditingProject>, onError: (String) -> Void
    ) async -> [MediaClip]? {
        let files = importable(urls)
        guard !files.isEmpty,
              let copying = filesToCopy(files, copy: project.wrappedValue.copiesMediaOnImport, packageURL: packageURL)
        else { return nil }
        let imported = await importFiles(files, copying: copying, packageURL: packageURL, project: project, onError: onError)
        return imported.isEmpty ? nil : imported
    }
}
