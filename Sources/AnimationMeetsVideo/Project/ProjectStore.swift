import CoreMedia
import Foundation

struct ProjectLoadResult {
    var project: EditingProject
    /// Media files referenced by the project that couldn't be opened; clips
    /// using them were dropped from the timelines.
    var missingMedia: [URL]
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

    static let referenceMetadataFileName = "reference.json"
    static let audioEnvelopeFileName = "audio.bin"

    static func writeReference(_ reference: AssetReference, for assetID: UUID, in packageURL: URL) throws {
        let folder = referenceFolder(for: assetID, in: packageURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(reference.metadata).write(to: folder.appending(path: referenceMetadataFileName), options: .atomic)
        if let envelope = reference.audioEnvelope {
            try envelope.encoded().write(to: folder.appending(path: audioEnvelopeFileName), options: .atomic)
        }
    }

    /// Deletes what was captured of the original: its metadata, audio
    /// envelope and pictures. The change scores stay, since scene detection
    /// uses them. This can't be undone; `save` calls it for every asset
    /// marked `referenceForgotten`.
    static func forgetReference(for assetID: UUID, in packageURL: URL) throws {
        let folder = referenceFolder(for: assetID, in: packageURL)
        let fileManager = FileManager.default
        for name in [referenceMetadataFileName, audioEnvelopeFileName, thumbnailFolderName] {
            let url = folder.appending(path: name)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
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
    @discardableResult
    static func save(
        _ project: EditingProject,
        to packageURL: URL,
        copying: Set<UUID> = [],
        changeScores: [UUID: ChangeScoreTrack] = [:],
        references: [UUID: AssetReference] = [:],
        thumbnails: [UUID: ReferenceThumbnails] = [:],
        beats: [UUID: BeatTrack] = [:],
        discardingBeats discardedBeats: Set<UUID> = [],
        previousPackageURL: URL? = nil
    ) async throws -> EditingProject {
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

        for (assetID, track) in changeScores where project.mediaClip(id: assetID) != nil {
            try writeChangeScores(track, for: assetID, in: packageURL)
        }
        for assetID in discardedBeats where beats[assetID] == nil {
            let url = referenceFolder(for: assetID, in: packageURL).appending(path: beatFileName)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        for (assetID, track) in beats where project.mediaClip(id: assetID) != nil {
            try writeBeats(track, for: assetID, in: packageURL)
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

        try encode(project, packageURL: packageURL)
            .write(to: packageURL.appending(path: projectFileName), options: .atomic)
        return project
    }

    private static func encode(_ project: EditingProject, packageURL: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(makeFile(from: project, packageURL: packageURL))
        data.append(0x0A)
        return data
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
                                volume: clip.volume == AnimatedValue(0.0) ? nil : ProjectFile.PropertyEntry(clip.volume) { $0 }
                            )
                        },
                        volume: layer.kind.isAudio && layer.volume != AnimatedValue(0.0)
                            ? ProjectFile.PropertyEntry(layer.volume) { $0 } : nil
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
                    alignmentOffset: clip.alignmentOffset == .zero ? nil : ProjectFile.TimeEntry(clip.alignmentOffset),
                    previousPaths: clip.previousPaths.isEmpty ? nil : clip.previousPaths,
                    fileStamp: clip.acceptedStamp,
                    referenceForgotten: clip.referenceForgotten ? true : nil
                )
            },
            timelines: timelines
        )
    }

    // MARK: Load

    /// Loads a package. `importMedia` reads a media file's metadata; it is a
    /// parameter so tests can run without real footage. `projectFile` reads
    /// the edit from another file, such as a backup, instead of
    /// `project.json`; paths in it are still relative to the package.
    static func load(
        from packageURL: URL,
        projectFile: URL? = nil,
        importMedia: @Sendable (URL) async throws -> MediaClip = { try await MediaImporter.importClip(at: $0) }
    ) async throws -> ProjectLoadResult {
        try validatePackage(at: packageURL)
        let fileURL = projectFile ?? packageURL.appending(path: projectFileName)
        let data = try Data(contentsOf: fileURL)

        let version = (try? JSONDecoder().decode(ProjectFileHeader.self, from: data))?.formatVersion
        guard let version, version >= 1 else {
            throw ProjectStoreError.unsupportedVersion(nil)
        }
        // Older files aren't migrated, and newer ones can't be read.
        guard version == ProjectFile.currentVersion else {
            throw ProjectStoreError.unsupportedVersion(version)
        }
        let file: ProjectFile
        do {
            try StrictJSON.validate(data, against: ProjectFile.shape)
            file = try JSONDecoder().decode(ProjectFile.self, from: data)
        } catch let problem as JSONShapeError {
            throw ProjectStoreError.invalidFile(problem.sentence)
        } catch let problem as DecodingError {
            throw ProjectStoreError.invalidFile(problem.sentenceForProject)
        }

        var importedClips: [UUID: MediaClip] = [:]
        var orderedIDs: [UUID] = []
        var missingMedia: [URL] = []
        var changedMedia: [UUID] = []
        for asset in file.assets {
            let url = asset.path.hasPrefix("/")
                ? URL(fileURLWithPath: asset.path)
                : packageURL.appending(path: asset.path)
            do {
                var clip = try await importMedia(url)
                clip.id = asset.id
                clip.name = asset.name
                clip.sceneEdits = asset.sceneEdits?.edits ?? SceneEdits()
                clip.alignmentOffset = asset.alignmentOffset?.time ?? .zero
                clip.previousPaths = asset.previousPaths ?? []
                clip.referenceForgotten = asset.referenceForgotten ?? false
                clip.acceptedStamp = asset.fileStamp ?? FileStamp(url: url)
                if let saved = asset.fileStamp, saved != FileStamp(url: url) { changedMedia.append(asset.id) }
                importedClips[asset.id] = clip
                orderedIDs.append(asset.id)
            } catch {
                missingMedia.append(url)
            }
        }

        let timelineIDs = Set(file.timelines.map(\.id))

        func resolveSource(_ entry: ProjectFile.SourceEntry) -> ClipSource? {
            switch entry.kind {
            case .media: importedClips[entry.id] != nil ? .media(entry.id) : nil
            case .timeline: timelineIDs.contains(entry.id) ? .timeline(entry.id) : nil
            }
        }

        let timelines: [Timeline] = file.timelines.map { entry in
            Timeline(
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
                                effects: (clipEntry.effects ?? []).compactMap(\.effect),
                                volume: clipEntry.volume?.property(default: 0.0) { AudioLevel.clamped($0) } ?? AnimatedValue(0.0)
                            )
                        },
                        volume: layerEntry.volume?.property(default: 0.0) { AudioLevel.clamped($0) } ?? AnimatedValue(0.0)
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
        var thumbnailed: Set<UUID> = []
        for id in orderedIDs {
            beats[id] = readBeats(for: id, in: packageURL)
            scores[id] = readChangeScores(for: id, in: packageURL)
            // Left behind only if saving stopped partway; it is deleted at the next save.
            guard importedClips[id]?.referenceForgotten != true else { continue }
            if hasThumbnails(for: id, in: packageURL) { thumbnailed.insert(id) }
            references[id] = readReference(for: id, in: packageURL)
        }
        return ProjectLoadResult(project: project, missingMedia: missingMedia, changedMedia: changedMedia, changeScores: scores, beats: beats, references: references, assetsWithThumbnails: thumbnailed)
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
