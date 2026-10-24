import CoreMedia
import Foundation
import UniformTypeIdentifiers

struct ProjectLoadResult {
    var project: EditingProject
    /// Media files referenced by the project that couldn't be opened. Their
    /// assets and clips stay in the project, offline (see `offlineMedia`).
    var missingMedia: [URL]
    /// The assets whose file couldn't be opened, kept from what the project
    /// saved about them so that saving doesn't lose them or their clips.
    var offlineMedia: [UUID] = []
    /// Assets whose file differs from the one the project last accepted, so
    /// it was swapped outside the app and needs a sync check.
    var changedMedia: [UUID] = []
    /// Saved change scores found in `Reference/`, by asset ID. Assets with no
    /// entry haven't been analyzed yet.
    var changeScores: [UUID: ChangeScoreTrack] = [:]
    /// Saved beats found in `Reference/`, by asset ID, likewise.
    var beats: [UUID: BeatTrack] = [:]
    /// Saved reference data of each asset's original file, by asset ID.
    var references: [UUID: AssetReference] = [:]
    /// Assets whose reference thumbnails are saved. The pictures themselves
    /// are read with `readThumbnails` when needed.
    var assetsWithThumbnails: Set<UUID> = []
    /// The file each loaded score and beat result was computed from. Results
    /// whose record is missing or no longer fits the asset's file are not
    /// loaded at all; `rejectedAnalysis` says why, and they are analyzed again.
    var analysisSources = AnalysisSources()
    /// The original footage's saved scores, by asset ID, for aligning a
    /// replacement. Not loaded for an asset whose original was forgotten.
    var originalScores: [UUID: ChangeScoreTrack] = [:]
    var rejectedAnalysis: [UUID: [AnalysisKind: AnalysisRejection]] = [:]
}

/// A media file that saving would copy into the project package.
struct MediaCopyCandidate {
    var clipID: UUID
    var sourceURL: URL
    var byteCount: Int64
    /// True when the copy is an instant copy-on-write clone that uses no
    /// extra disk space (same APFS volume).
    var isClone: Bool
}

enum ProjectStore {
    static let packageExtension = "amv"
    /// The project type the app bundle declares (`Packaging/Info.plist`).
    static let packageTypeIdentifier = "com.jhgfd.animationmeetsvideo.project"
    /// The project package type. Run without the bundle (`swift run`) the
    /// system doesn't know the declared identifier, so the type is made
    /// from the extension instead.
    static let packageType: UTType = UTType(packageTypeIdentifier)
        ?? UTType(filenameExtension: packageExtension, conformingTo: .package)
        ?? .package
    static let projectFileName = "project.json"
    static let mediaFolderName = "Media"
    static let referenceFolderName = "Reference"
    static let cacheFolderName = "Cache"
    static let backupsFolderName = "Backups"
    static let lockFileName = ".lock"

    /// Resolves what the user picked to the package directory: either the
    /// package itself or the `project.json` inside it.
    static func packageURL(forSelection url: URL) -> URL {
        url.lastPathComponent == projectFileName ? url.deletingLastPathComponent() : url
    }

    /// Throws `notAProject` unless the folder contains a project file.
    static func validatePackage(at packageURL: URL) throws {
        let fileURL = packageURL.appending(path: projectFileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ProjectStoreError.notAProject(packageURL.lastPathComponent)
        }
    }

    // MARK: Package layout

    /// Creates the package directory and its standard subfolders. Safe to
    /// call on an existing package.
    static func preparePackage(at packageURL: URL) throws {
        let fileManager = FileManager.default
        for folder in [mediaFolderName, referenceFolderName, cacheFolderName, backupsFolderName] {
            try fileManager.createDirectory(
                at: packageURL.appending(path: folder, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }

        // The cache is disposable and shouldn't be backed up or synced.
        var cacheURL = packageURL.appending(path: cacheFolderName, directoryHint: .isDirectory)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? cacheURL.setResourceValues(values)

        let ignoreURL = packageURL.appending(path: ".gitignore")
        if !fileManager.fileExists(atPath: ignoreURL.path) {
            try "\(cacheFolderName)/\n\(backupsFolderName)/\n\(lockFileName)\n".write(to: ignoreURL, atomically: true, encoding: .utf8)
        }
        markAsPackage(packageURL)
    }

    /// Sets the folder's package flag, so Finder and open and save panels
    /// show it as one item even where no installed app declares `.amv`.
    /// The flag is file metadata that some copies drop (zip, git, some
    /// sync services), so it's set again on every open and save.
    static func markAsPackage(_ packageURL: URL) {
        var url = packageURL
        var values = URLResourceValues()
        values.isPackage = true
        try? url.setResourceValues(values)
    }

    // MARK: Reference data

    static let changeScoreFileName = "signature.bin"

    static func referenceFolder(for assetID: UUID, in packageURL: URL) -> URL {
        packageURL
            .appending(path: referenceFolderName, directoryHint: .isDirectory)
            .appending(path: assetID.uuidString, directoryHint: .isDirectory)
    }

    static func writeChangeScores(_ track: ChangeScoreTrack, for assetID: UUID, in packageURL: URL) throws {
        let folder = referenceFolder(for: assetID, in: packageURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try track.encoded().write(to: folder.appending(path: changeScoreFileName), options: .atomic)
    }

    /// Nil when the asset was never analyzed or the file can't be read; the
    /// scores are recomputable, so a damaged file just means analyzing again.
    static func readChangeScores(for assetID: UUID, in packageURL: URL) -> ChangeScoreTrack? {
        let url = referenceFolder(for: assetID, in: packageURL).appending(path: changeScoreFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ChangeScoreTrack(decoding: data)
    }

    /// Deletes an asset's saved change scores, for an explicit re-detect.
    static func removeChangeScores(for assetID: UUID, in packageURL: URL) throws {
        let url = referenceFolder(for: assetID, in: packageURL).appending(path: changeScoreFileName)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static let referenceMetadataFileName = "reference.json"
    static let audioEnvelopeFileName = "audio.bin"

    static func writeReference(_ reference: AssetReference, for assetID: UUID, in packageURL: URL) throws {
        let folder = referenceFolder(for: assetID, in: packageURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONFile.encode(reference.metadata).write(to: folder.appending(path: referenceMetadataFileName), options: .atomic)
        if let envelope = reference.audioEnvelope {
            try envelope.encoded().write(to: folder.appending(path: audioEnvelopeFileName), options: .atomic)
        }
    }

    /// Deletes what was captured of the original: its metadata, audio
    /// envelope, pictures and scores. The change scores of the file the
    /// asset uses now stay, since scene detection uses them. This can't be
    /// undone; `save` calls it for every asset marked `referenceForgotten`.
    static func forgetReference(for assetID: UUID, in packageURL: URL) throws {
        let folder = referenceFolder(for: assetID, in: packageURL)
        let fileManager = FileManager.default
        for name in [referenceMetadataFileName, audioEnvelopeFileName, thumbnailFolderName] {
            let url = folder.appending(path: name)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        try invalidate(.originalScores, for: assetID, in: packageURL)
    }

    /// Nil when there is no usable metadata snapshot. A missing or damaged
    /// envelope only costs the audio match, so it is dropped on its own.
    static func readReference(for assetID: UUID, in packageURL: URL) -> AssetReference? {
        let folder = referenceFolder(for: assetID, in: packageURL)
        guard let data = try? Data(contentsOf: folder.appending(path: referenceMetadataFileName)),
              let metadata = try? JSONDecoder().decode(AssetMetadataSnapshot.self, from: data)
        else {
            return nil
        }
        let envelope = (try? Data(contentsOf: folder.appending(path: audioEnvelopeFileName)))
            .flatMap { try? AudioEnvelope(decoding: $0) }
        return AssetReference(metadata: metadata, audioEnvelope: envelope)
    }

    static let beatFileName = "beats.bin"

    static func writeBeats(_ track: BeatTrack, for assetID: UUID, in packageURL: URL) throws {
        let folder = referenceFolder(for: assetID, in: packageURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try track.encoded().write(to: folder.appending(path: beatFileName), options: .atomic)
    }

    /// Nil when the asset's audio was never analyzed or the file can't be
    /// read; beats are recomputable, so a damaged file just means analyzing again.
    static func readBeats(for assetID: UUID, in packageURL: URL) -> BeatTrack? {
        let url = referenceFolder(for: assetID, in: packageURL).appending(path: beatFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? BeatTrack(decoding: data)
    }

    static let thumbnailFolderName = "thumbs"

    /// Writes the pictures to a scratch folder and renames it into place, so
    /// a folder that exists is always complete.
    static func writeThumbnails(_ thumbnails: ReferenceThumbnails, for assetID: UUID, in packageURL: URL) throws {
        let fileManager = FileManager.default
        let folder = referenceFolder(for: assetID, in: packageURL)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = folder.appending(path: thumbnailFolderName, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: final.path) else { return }

        let scratch = folder.appending(path: "\(thumbnailFolderName).partial", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: scratch)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        for frame in thumbnails.frames {
            try frame.jpeg.write(to: scratch.appending(path: thumbnailFileName(for: frame.time)))
        }
        try fileManager.moveItem(at: scratch, to: final)
    }

    static func hasThumbnails(for assetID: UUID, in packageURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = referenceFolder(for: assetID, in: packageURL).appending(path: thumbnailFolderName).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The saved pictures, in time order. Empty if none were saved.
    static func readThumbnails(for assetID: UUID, in packageURL: URL) -> ReferenceThumbnails {
        let folder = referenceFolder(for: assetID, in: packageURL).appending(path: thumbnailFolderName)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var frames: [ReferenceFrame] = []
        for name in names {
            guard let time = thumbnailTime(fromFileName: name),
                  let data = try? Data(contentsOf: folder.appending(path: name))
            else {
                continue
            }
            frames.append(ReferenceFrame(time: time, jpeg: data))
        }
        frames.sort { CMTimeCompare($0.time, $1.time) < 0 }
        return ReferenceThumbnails(frames: frames)
    }

    static func thumbnailFileName(for time: CMTime) -> String {
        "\(time.value)_\(time.timescale).jpg"
    }

    static func thumbnailTime(fromFileName name: String) -> CMTime? {
        guard name.hasSuffix(".jpg") else { return nil }
        let parts = name.dropLast(4).split(separator: "_")
        guard parts.count == 2, let value = Int64(parts[0]), let scale = Int32(parts[1]), scale > 0 else { return nil }
        return CMTime(value: value, timescale: scale)
    }

    /// Copies each asset's saved reference data, scores, beats and pictures
    /// from one package to another. Files already at the destination are
    /// kept. The original's data may exist nowhere else, so it must follow
    /// the project to a new package.
    static func copyReferenceData(for assetIDs: [UUID], from source: URL, to destination: URL) throws {
        let same = source.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !same else { return }
        let fileManager = FileManager.default
        for id in assetIDs {
            let from = referenceFolder(for: id, in: source)
            guard let names = try? fileManager.contentsOfDirectory(atPath: from.path) else { continue }
            let to = referenceFolder(for: id, in: destination)
            try fileManager.createDirectory(at: to, withIntermediateDirectories: true)
            for name in names where !name.hasSuffix(".partial") {
                let target = to.appending(path: name)
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                try fileManager.copyItem(at: from.appending(path: name), to: target)
            }
        }
    }

    // MARK: Media consolidation

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

    private static func isInside(_ url: URL, package packageURL: URL) -> Bool {
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

    // MARK: Save

    /// Writes the package and returns the project with any copied media
    /// pointing at its new location. `copying` lists the media IDs to copy
    /// into `Media/`; on APFS a same-volume copy is a clone and costs no
    /// extra space. `changeScores` are written to `Reference/`; pass only the
    /// ones that aren't saved yet, and so are `references` and `thumbnails`.
    /// The reference data of assets marked `referenceForgotten` is deleted
    /// rather than written. For Save As, `previousPackageURL` is where the
    /// project was saved before: what it holds in `Reference/` is copied
    /// first, since only unsaved results are passed in. `discardedBeats`
    /// are assets whose saved beats came from a file they no longer use.
    ///
    /// Runs through the `PackageCoordinator`, after everything already queued
    /// on the package (and, for Save As, on the previous one).
    @discardableResult
    static func save(
        _ project: EditingProject,
        to packageURL: URL,
        copying: Set<UUID> = [],
        changeScores: [UUID: ChangeScoreTrack] = [:],
        references: [UUID: AssetReference] = [:],
        thumbnails: [UUID: ReferenceThumbnails] = [:],
        beats: [UUID: BeatTrack] = [:],
        originalScores: [UUID: ChangeScoreTrack] = [:],
        sources: AnalysisSources = AnalysisSources(),
        discardingBeats discardedBeats: Set<UUID> = [],
        invalidatingScores invalidatedScores: Set<UUID> = [],
        previousPackageURL: URL? = nil
    ) async throws -> EditingProject {
        try await PackageCoordinator.shared.run(on: [packageURL] + (previousPackageURL.map { [$0] } ?? [])) {
            try performSave(
                project, to: packageURL, copying: copying, changeScores: changeScores,
                references: references, thumbnails: thumbnails, beats: beats, originalScores: originalScores, sources: sources,
                discardingBeats: discardedBeats, invalidatingScores: invalidatedScores,
                previousPackageURL: previousPackageURL
            )
        }
    }

    private static func performSave(
        _ project: EditingProject,
        to packageURL: URL,
        copying: Set<UUID>,
        changeScores: [UUID: ChangeScoreTrack],
        references: [UUID: AssetReference],
        thumbnails: [UUID: ReferenceThumbnails],
        beats: [UUID: BeatTrack],
        originalScores: [UUID: ChangeScoreTrack],
        sources: AnalysisSources,
        discardingBeats discardedBeats: Set<UUID>,
        invalidatingScores invalidatedScores: Set<UUID>,
        previousPackageURL: URL?
    ) throws -> EditingProject {
        try preparePackage(at: packageURL)
        if let previousPackageURL {
            try copyReferenceData(
                for: project.clips.filter { !$0.referenceForgotten }.map(\.id),
                from: previousPackageURL, to: packageURL
            )
        }

        var project = project
        for index in project.clips.indices {
            let clip = project.clips[index]
            guard copying.contains(clip.id), let source = clip.url, !isInside(source, package: packageURL) else { continue }
            let destination = try copyIntoPackage(source, packageURL: packageURL)
            project.clips[index].url = destination
            project.clips[index].acceptedStamp = FileStamp(url: destination)
        }

        // Retired results go first, and a retirement that can't be made
        // durable fails the save, so an outdated result can't return.
        for assetID in invalidatedScores where changeScores[assetID] == nil {
            try invalidate(.scores, for: assetID, in: packageURL)
        }
        for assetID in discardedBeats where beats[assetID] == nil {
            try invalidate(.beats, for: assetID, in: packageURL)
        }
        for (assetID, track) in changeScores where project.mediaClip(id: assetID) != nil {
            try writeChangeScores(track, for: assetID, in: packageURL, source: sources.scores[assetID])
        }
        for (assetID, track) in beats where project.mediaClip(id: assetID) != nil {
            try writeBeats(track, for: assetID, in: packageURL, source: sources.beats[assetID])
        }
        // A forgotten original's data is deleted only now, so that undoing
        // Forget Original before saving loses nothing.
        let forgotten = Set(project.clips.filter(\.referenceForgotten).map(\.id))
        for assetID in forgotten {
            try forgetReference(for: assetID, in: packageURL)
        }
        for (assetID, reference) in references where project.mediaClip(id: assetID) != nil && !forgotten.contains(assetID) {
            try writeReference(reference, for: assetID, in: packageURL)
        }
        for (assetID, pictures) in thumbnails where project.mediaClip(id: assetID) != nil && !forgotten.contains(assetID) {
            try writeThumbnails(pictures, for: assetID, in: packageURL)
        }
        for (assetID, track) in originalScores where project.mediaClip(id: assetID) != nil && !forgotten.contains(assetID) {
            try writeOriginalScores(track, for: assetID, in: packageURL, source: sources.originalScores[assetID])
        }

        try encode(project, packageURL: packageURL)
            .write(to: packageURL.appending(path: projectFileName), options: .atomic)
        // Matroska files imported before the project had a package, or
        // copied into it just now, get their reference movies here. A
        // movie is only an index, so one that can't be made fails no save:
        // it's tried again on opening.
        for clip in project.clips {
            guard let url = clip.url, MatroskaMedia.isMatroska(url) else { continue }
            _ = try? MatroskaMedia.prepare(url, in: MatroskaMedia.folder(in: packageURL))
        }
        return project
    }

    private static func encode(_ project: EditingProject, packageURL: URL) throws -> Data {
        try JSONFile.encode(makeFile(from: project, packageURL: packageURL))
    }

    // MARK: Backups

    static let backupPrefix = "autosave-"

    /// Writes a timestamped copy of the project into `Backups/` and deletes
    /// the oldest beyond `limit`. It never touches `project.json`, so an
    /// autosave can't overwrite work the person chose to save. To recover,
    /// copy a backup over `project.json`.
    @discardableResult
    static func writeBackup(
        of project: EditingProject,
        in packageURL: URL,
        now: Date = Date(),
        keeping limit: Int = 20
    ) throws -> URL {
        let folder = packageURL.appending(path: backupsFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = folder.appending(path: "\(backupPrefix)\(formatter.string(from: now)).json")
        try encode(project, packageURL: packageURL).write(to: url, options: .atomic)

        let backups = (try FileManager.default.contentsOfDirectory(atPath: folder.path))
            .filter { $0.hasPrefix(backupPrefix) && $0.hasSuffix(".json") }
            .sorted()
        for name in backups.dropLast(max(limit, 1)) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
        return url
    }

    /// The newest autosave, when it was written after `project.json` and
    /// holds something different: work that was never saved, as when the
    /// app quit without saving or crashed.
    static func unsavedBackup(in packageURL: URL) -> URL? {
        let folder = packageURL.appending(path: backupsFolderName, directoryHint: .isDirectory)
        let projectURL = packageURL.appending(path: projectFileName)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              let newest = names.filter({ $0.hasPrefix(backupPrefix) && $0.hasSuffix(".json") }).sorted().last,
              let saved = modificationDate(of: projectURL)
        else {
            return nil
        }
        let backup = folder.appending(path: newest)
        guard let written = modificationDate(of: backup), written > saved,
              (try? Data(contentsOf: backup)) != (try? Data(contentsOf: projectURL))
        else {
            return nil
        }
        return backup
    }

    /// Marks every autosave as older than `project.json`, once the person
    /// has chosen not to keep what they hold, so they aren't offered again.
    /// The backups themselves are kept.
    static func markBackupsSeen(in packageURL: URL) {
        let folder = packageURL.appending(path: backupsFolderName, directoryHint: .isDirectory)
        guard let saved = modificationDate(of: packageURL.appending(path: projectFileName)),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else {
            return
        }
        for name in names where name.hasPrefix(backupPrefix) {
            let url = folder.appending(path: name)
            // A second earlier, since dates round on disk and an exact copy
            // could still read as newer.
            if let written = modificationDate(of: url), written > saved {
                try? FileManager.default.setAttributes([.modificationDate: saved.addingTimeInterval(-1)], ofItemAtPath: url.path)
            }
        }
    }

    /// `markBackupsSeen`, in turn with everything else that changes the package.
    static func markBackupsSeenQueued(in packageURL: URL) async {
        _ = try? await PackageCoordinator.shared.run(on: [packageURL]) { markBackupsSeen(in: packageURL) }
    }

    /// Moves an existing package to the Trash, after anything already queued
    /// on it. With `checkingLock`, a package another window or app has open
    /// is refused (the lock is released again at once).
    static func trashPackage(at url: URL, checkingLock: Bool) async throws {
        try await PackageCoordinator.shared.run(on: [url]) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            if checkingLock, (try? validatePackage(at: url)) != nil {
                _ = try ProjectLock.acquire(at: url)
            }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try? fresh.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func makeFile(from project: EditingProject, packageURL: URL) -> ProjectFile {
        let urlClips = project.clips.filter { $0.url != nil }
        let mediaIDs = Set(urlClips.map(\.id))
        let timelineIDs = Set(project.timelines.map(\.id))

        func relativePath(for url: URL) -> String {
            if isInside(url, package: packageURL) {
                let packagePath = packageURL.standardizedFileURL.resolvingSymlinksInPath().path
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                return String(path.dropFirst(packagePath.count + 1))
            }
            return url.path
        }

        func sourceEntry(for source: ClipSource) -> ProjectFile.SourceEntry? {
            switch source {
            case .media(let id): mediaIDs.contains(id) ? ProjectFile.SourceEntry(kind: .media, id: id) : nil
            case .timeline(let id): timelineIDs.contains(id) ? ProjectFile.SourceEntry(kind: .timeline, id: id) : nil
            case .adjustment: ProjectFile.SourceEntry(kind: .adjustment, id: nil)
            case .graphic: ProjectFile.SourceEntry(kind: .graphic, id: nil)
            }
        }

        let timelines = project.timelines.map { timeline in
            ProjectFile.TimelineEntry(
                id: timeline.id,
                name: timeline.name,
                width: timeline.frameSize.width,
                height: timeline.frameSize.height,
                frameRate: timeline.frameRate,
                colorSpace: timeline.colorSpace.rawValue,
                layers: timeline.layers.map { layer in
                    ProjectFile.LayerEntry(
                        id: layer.id,
                        customName: layer.customName,
                        kind: layer.kind.rawValue,
                        clips: layer.clips.compactMap { clip in
                            guard let source = sourceEntry(for: clip.source) else { return nil }
                            return ProjectFile.ClipEntry(
                                id: clip.id,
                                source: source,
                                startOffset: ProjectFile.TimeEntry(clip.startOffset),
                                trimStart: ProjectFile.TimeEntry(clip.trimStart),
                                trimEnd: ProjectFile.TimeEntry(clip.trimEnd),
                                autoMatteEnabled: clip.autoMatteEnabled,
                                streams: clip.streams == .videoAndAudio ? nil : clip.streams.rawValue,
                                transitionIn: clip.transitionIn.map(ProjectFile.TransitionEntry.init),
                                transitionOut: clip.transitionOut.map(ProjectFile.TransitionEntry.init),
                                anchorPoint: clip.anchorPoint == AnimatedValue(Vector2.zero)
                                    ? nil : ProjectFile.PropertyEntry(clip.anchorPoint) { [$0.x, $0.y] },
                                effects: clip.effects.isEmpty ? nil : clip.effects.map(ProjectFile.EffectEntry.init),
                                audioEffects: clip.audioEffects.isEmpty ? nil : clip.audioEffects.map(ProjectFile.EffectEntry.init),
                                volume: clip.volume == AnimatedValue(0.0) ? nil : ProjectFile.PropertyEntry(clip.volume) { $0 },
                                pan: clip.pan == AnimatedValue(0.0) ? nil : ProjectFile.PropertyEntry(clip.pan) { $0 },
                                passThrough: clip.passThrough ? true : nil,
                                time: ProjectFile.ClipTimeEntry(clip.time),
                                shutter: ProjectFile.ShutterEntry(clip.shutter),
                                reach: clip.source == .adjustment ? clip.reach : nil,
                                enabled: clip.enabled ? nil : false,
                                soundMuted: clip.soundMuted ? true : nil,
                                music: layer.kind == .music ? nil : clip.music.map(ProjectFile.MusicEntry.init),
                                followsMusic: clip.followsMusic ? nil : false
                            )
                        },
                        volume: layer.kind.isAudio && layer.volume != AnimatedValue(0.0)
                            ? ProjectFile.PropertyEntry(layer.volume) { $0 } : nil,
                        pan: layer.kind.isAudio && layer.pan != AnimatedValue(0.0)
                            ? ProjectFile.PropertyEntry(layer.pan) { $0 } : nil,
                        audioEffects: layer.kind.isAudio && !layer.audioEffects.isEmpty
                            ? layer.audioEffects.map(ProjectFile.EffectEntry.init) : nil,
                        adjustment: layer.isAdjustment ? true : nil
                    )
                },
                sections: timeline.sections.isEmpty ? nil : timeline.sections.map { section in
                    ProjectFile.SectionEntry(
                        id: section.id, name: section.name,
                        start: ProjectFile.TimeEntry(section.start), end: ProjectFile.TimeEntry(section.end)
                    )
                }
            )
        }

        return ProjectFile(
            formatVersion: ProjectFile.currentVersion,
            id: project.id,
            name: project.name,
            rootTimelineID: project.rootTimelineID,
            defaultSensitivity: project.defaultSensitivity == SceneDetector.balancedSensitivity ? nil : project.defaultSensitivity,
            copiesMediaOnImport: project.copiesMediaOnImport ? nil : false,
            canvasMargin: project.canvasMargin == EditingProject.defaultCanvasMargin ? nil : project.canvasMargin,
            assets: urlClips.map { clip in
                ProjectFile.AssetEntry(
                    id: clip.id,
                    name: clip.name,
                    path: relativePath(for: clip.url!),
                    sceneEdits: clip.sceneEdits == SceneEdits() ? nil : ProjectFile.SceneEditsEntry(clip.sceneEdits),
                    beatMap: clip.beatMap.isEmpty ? nil : ProjectFile.BeatMapEntry(clip.beatMap),
                    alignmentOffset: clip.alignmentOffset == .zero ? nil : ProjectFile.TimeEntry(clip.alignmentOffset),
                    originalDuration: clip.originalDuration.map(ProjectFile.TimeEntry.init),
                    previousPaths: clip.previousPaths.isEmpty ? nil : clip.previousPaths,
                    fileStamp: clip.acceptedStamp,
                    referenceForgotten: clip.referenceForgotten ? true : nil,
                    kind: clip.kind.rawValue,
                    duration: ProjectFile.TimeEntry(clip.duration),
                    frameRate: clip.frameRate,
                    codec: clip.codecName,
                    colorSpace: clip.colorSpace.rawValue,
                    hasAudio: clip.hasAudio
                )
            },
            timelines: timelines
        )
    }

    // MARK: Load

    /// Loads a package. `importMedia` reads a media file's metadata, by
    /// default with `MediaImporter` into this package; it is a parameter so
    /// tests can run without real footage. `projectFile` reads
    /// the edit from another file, such as a backup, instead of
    /// `project.json`; paths in it are still relative to the package.
    static func load(
        from packageURL: URL,
        projectFile: URL? = nil,
        importMedia: (@Sendable (URL) async throws -> MediaClip)? = nil
    ) async throws -> ProjectLoadResult {
        try validatePackage(at: packageURL)
        let importMedia = importMedia ?? { try await MediaImporter.importClip(at: $0, packageURL: packageURL) }
        let fileURL = projectFile ?? packageURL.appending(path: projectFileName)
        let data = try Data(contentsOf: fileURL)

        guard let version = JSONFile.formatVersion(of: data), version >= 1 else {
            throw ProjectStoreError.unsupportedVersion(nil)
        }
        // Older files aren't migrated, and newer ones can't be read.
        guard version == ProjectFile.currentVersion else {
            throw ProjectStoreError.unsupportedVersion(version)
        }
        let file = try JSONFile.decode(ProjectFile.self, from: data, shape: ProjectFile.shape, failure: ProjectStoreError.invalidFile)

        var importedClips: [UUID: MediaClip] = [:]
        var orderedIDs: [UUID] = []
        var missingMedia: [URL] = []
        var offlineMedia: [UUID] = []
        var changedMedia: [UUID] = []
        for asset in file.assets {
            let url = asset.path.hasPrefix("/")
                ? URL(fileURLWithPath: asset.path)
                : packageURL.appending(path: asset.path)
            var clip: MediaClip
            do {
                clip = try await importMedia(url)
                if let saved = asset.fileStamp, saved != FileStamp(url: url) { changedMedia.append(asset.id) }
            } catch {
                // Kept, offline: dropping it would lose its clips for good at
                // the next save, as when a drive simply isn't plugged in.
                missingMedia.append(url)
                offlineMedia.append(asset.id)
                clip = offlineClip(for: asset, at: url, in: packageURL, timelines: file.timelines)
            }
            clip.id = asset.id
            clip.name = asset.name
            clip.sceneEdits = asset.sceneEdits?.edits ?? SceneEdits()
            clip.beatMap = asset.beatMap?.map ?? BeatMap()
            clip.alignmentOffset = asset.alignmentOffset?.time ?? .zero
            clip.originalDuration = asset.originalDuration?.time
            clip.previousPaths = asset.previousPaths ?? []
            clip.referenceForgotten = asset.referenceForgotten ?? false
            clip.acceptedStamp = asset.fileStamp ?? FileStamp(url: url)
            importedClips[asset.id] = clip
            orderedIDs.append(asset.id)
        }

        let timelineIDs = Set(file.timelines.map(\.id))

        func resolveSource(_ entry: ProjectFile.SourceEntry) -> ClipSource? {
            switch entry.kind {
            case .media: entry.id.flatMap { importedClips[$0] != nil ? ClipSource.media($0) : nil }
            case .timeline: entry.id.flatMap { timelineIDs.contains($0) ? ClipSource.timeline($0) : nil }
            case .adjustment: .adjustment
            case .graphic: .graphic
            }
        }

        let timelines: [Timeline] = file.timelines.map { entry in
            let layerIDs = Set(entry.layers.map(\.id))
            return Timeline(
                id: entry.id,
                name: entry.name,
                layers: entry.layers.map { layerEntry in
                    TimelineLayer(
                        id: layerEntry.id,
                        customName: layerEntry.customName,
                        kind: LayerKind(rawValue: layerEntry.kind) ?? .video,
                        clips: layerEntry.clips.compactMap { clipEntry in
                            guard let source = resolveSource(clipEntry.source) else { return nil }
                            return TimelineClip(
                                id: clipEntry.id,
                                source: source,
                                startOffset: clipEntry.startOffset.time,
                                trimStart: clipEntry.trimStart.time,
                                trimEnd: clipEntry.trimEnd.time,
                                autoMatteEnabled: clipEntry.autoMatteEnabled,
                                streams: clipEntry.streams.flatMap(ClipStreams.init(rawValue:)) ?? .videoAndAudio,
                                transitionIn: clipEntry.transitionIn?.transition,
                                transitionOut: clipEntry.transitionOut?.transition,
                                anchorPoint: clipEntry.anchorPoint?.property(default: .zero) {
                                    $0.count == 2 ? Vector2(x: $0[0], y: $0[1]) : nil
                                } ?? AnimatedValue(Vector2.zero),
                                effects: (clipEntry.effects ?? []).compactMap(\.effect).filter { !$0.kind.isAudio },
                                audioEffects: (clipEntry.audioEffects ?? []).compactMap(\.effect).filter(\.kind.isAudio),
                                volume: clipEntry.volume?.property(default: 0.0) { AudioLevel.clamped($0) } ?? AnimatedValue(0.0),
                                pan: clipEntry.pan?.property(default: 0.0) { AudioPan.clamped($0) } ?? AnimatedValue(0.0),
                                passThrough: clipEntry.passThrough ?? false,
                                time: clipEntry.time?.time ?? ClipTime(),
                                shutter: clipEntry.shutter?.shutter ?? ClipShutter(),
                                // A reach that names no layer of this timeline
                                // reaches every layer below. Older projects
                                // kept one reach for the whole layer.
                                reach: source == .adjustment
                                    ? (clipEntry.reach ?? layerEntry.reach).flatMap { layerIDs.contains($0) ? $0 : nil } : nil,
                                enabled: clipEntry.enabled ?? true,
                                soundMuted: clipEntry.soundMuted ?? false,
                                music: clipEntry.followsMusic == false ? nil : clipEntry.music?.attachment,
                                followsMusic: clipEntry.followsMusic ?? true
                            )
                        },
                        volume: layerEntry.volume?.property(default: 0.0) { AudioLevel.clamped($0) } ?? AnimatedValue(0.0),
                        pan: layerEntry.pan?.property(default: 0.0) { AudioPan.clamped($0) } ?? AnimatedValue(0.0),
                        audioEffects: (layerEntry.audioEffects ?? []).compactMap(\.effect).filter(\.kind.isAudio),
                        isAdjustment: layerEntry.adjustment ?? false
                    )
                },
                frameSize: CGSize(width: entry.width, height: entry.height),
                frameRate: entry.frameRate,
                colorSpace: ProjectColorSpace(rawValue: entry.colorSpace) ?? .rec709,
                sections: (entry.sections ?? [])
                    .map { TimelineSection(id: $0.id, name: $0.name, start: $0.start.time, end: $0.end.time) }
                    .filter { $0.end > $0.start }
                    .sorted { $0.start < $1.start }
            )
        }

        guard let first = timelines.first else {
            throw ProjectStoreError.noTimelines
        }
        let rootID = timelineIDs.contains(file.rootTimelineID) ? file.rootTimelineID : first.id

        var project = EditingProject(
            id: file.id,
            name: file.name,
            clips: orderedIDs.compactMap { importedClips[$0] },
            timelines: timelines,
            rootTimelineID: rootID,
            defaultSensitivity: file.defaultSensitivity ?? SceneDetector.balancedSensitivity,
            copiesMediaOnImport: file.copiesMediaOnImport ?? true,
            canvasMargin: file.canvasMargin ?? EditingProject.defaultCanvasMargin
        )
        project.alignClipLengthsToFrames()
        var scores: [UUID: ChangeScoreTrack] = [:]
        var references: [UUID: AssetReference] = [:]
        var beats: [UUID: BeatTrack] = [:]
        var sources = AnalysisSources()
        var original: [UUID: ChangeScoreTrack] = [:]
        var rejected: [UUID: [AnalysisKind: AnalysisRejection]] = [:]
        var thumbnailed: Set<UUID> = []
        for id in orderedIDs {
            // Results describe the file the asset has now, so they are used
            // only when their record matches the file the project accepted.
            let identity = importedClips[id]?.acceptedStamp
            switch readVerifiedBeats(for: id, in: packageURL, identity: identity) {
            case .valid(let track, let source): beats[id] = track; sources.beats[id] = source
            case .rejected(let reason): rejected[id, default: [:]][.beats] = reason
            case .absent: break
            }
            switch readVerifiedChangeScores(for: id, in: packageURL, identity: identity) {
            case .valid(let track, let source): scores[id] = track; sources.scores[id] = source
            case .rejected(let reason): rejected[id, default: [:]][.scores] = reason
            case .absent: break
            }
            // Left behind only if saving stopped partway; it is deleted at the next save.
            guard importedClips[id]?.referenceForgotten != true else { continue }
            if hasThumbnails(for: id, in: packageURL) { thumbnailed.insert(id) }
            references[id] = readReference(for: id, in: packageURL)
            switch readVerifiedOriginalScores(for: id, in: packageURL) {
            case .valid(let track, let source): original[id] = track; sources.originalScores[id] = source
            case .rejected(let reason): rejected[id, default: [:]][.originalScores] = reason
            case .absent: break
            }
        }
        // Reference movies of files since moved, changed or removed.
        MatroskaMedia.removeUnused(in: packageURL, keeping: Set(project.clips.compactMap { clip in
            clip.url.flatMap { MatroskaMedia.isMatroska($0) ? MatroskaMedia.movieName(for: $0) : nil }
        }))
        return ProjectLoadResult(project: project, missingMedia: missingMedia, offlineMedia: offlineMedia, changedMedia: changedMedia, changeScores: scores, beats: beats, references: references, assetsWithThumbnails: thumbnailed, analysisSources: sources, originalScores: original, rejectedAnalysis: rejected)
    }
}

extension ProjectStore {
    /// An asset whose file couldn't be opened, described from what the
    /// project saved about it; for files saved before that, from the
    /// original's reference data (unless the asset has since been
    /// replaced), and failing that from how its clips use it. Its length
    /// always covers its clips, so their trims stay valid.
    fileprivate static func offlineClip(
        for asset: ProjectFile.AssetEntry,
        at url: URL,
        in packageURL: URL,
        timelines: [ProjectFile.TimelineEntry]
    ) -> MediaClip {
        let replaced = !(asset.previousPaths ?? []).isEmpty || asset.alignmentOffset != nil
        let reference = asset.referenceForgotten == true || replaced
            ? nil : readReference(for: asset.id, in: packageURL)?.metadata
        let layers = timelines.flatMap(\.layers)
        let uses = layers.flatMap(\.clips).filter { $0.source.kind == .media && $0.source.id == asset.id }
        let longestUse = uses.map(\.trimEnd.time).max() ?? .zero
        let onVideoLayer = layers.contains { layer in
            layer.kind != LayerKind.sound.rawValue && layer.kind != LayerKind.music.rawValue
                && layer.clips.contains { $0.source.kind == .media && $0.source.id == asset.id }
        }
        let kind = asset.kind.flatMap(MediaKind.init(rawValue:))
            ?? reference.map { $0.isVideo ? MediaKind.video : .audio }
            ?? (onVideoLayer ? .video : .audio)
        let duration = asset.duration?.time ?? reference?.duration ?? longestUse
        return MediaClip(
            name: asset.name,
            kind: kind,
            url: url,
            duration: CMTimeMaximum(duration, longestUse),
            frameRate: asset.frameRate ?? reference?.frameRate ?? 0,
            colorSpace: asset.colorSpace.flatMap(ProjectColorSpace.init(rawValue:)) ?? .rec709,
            codecName: asset.codec ?? reference?.codecName ?? "Offline",
            hasAudio: asset.hasAudio ?? reference?.hasAudio ?? (kind == .audio || uses.contains { $0.streams == ClipStreams.audio.rawValue })
        )
    }
}

enum ProjectStoreError: LocalizedError {
    case noTimelines
    case notAProject(String)
    case unsupportedVersion(Int?)
    /// A project file with something in it this version doesn't recognize,
    /// and where (see `StrictJSON`).
    case invalidFile(String)
    case invalidTime(String)
    case locked(String?)

    var errorDescription: String? {
        switch self {
        case .noTimelines:
            "The project file doesn't contain any timelines."
        case .notAProject(let name):
            "“\(name)” isn't an Animation Meets Video project (no project.json inside)."
        case .unsupportedVersion(let version):
            if let version, version > ProjectFile.currentVersion {
                "This project was saved by a newer version of the app (format version \(version))."
            } else if let version {
                "This project uses format version \(version), which this version of the app can't open."
            } else {
                "This project file has no supported format version."
            }
        case .invalidFile(let detail):
            "The project can't be opened. \(detail)"
        case .locked(let holder):
            if let holder {
                "This project is already open in \(holder). Close it there first."
            } else {
                "This project is already open in another window or app. Close it there first."
            }
        case .invalidTime(let text):
            "“\(text)” isn't a valid time. Use a rational number of seconds such as 1001/24000s or 5s."
        }
    }
}

extension DecodingError {
    /// A decoding failure that got past `StrictJSON`, which should not
    /// happen, worded like its errors.
    var sentenceForProject: String {
        func path(_ codingPath: [CodingKey]) -> String {
            var text = ""
            for key in codingPath {
                if let index = key.intValue {
                    text += "[\(index)]"
                } else {
                    text = StrictJSON.join(text, key.stringValue)
                }
            }
            return text.isEmpty ? "the top level of the file" : text
        }
        switch self {
        case .keyNotFound(let key, let context):
            return "Missing \"\(key.stringValue)\" at \(path(context.codingPath))."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context.codingPath))."
        @unknown default:
            return "The file couldn't be read."
        }
    }
}
