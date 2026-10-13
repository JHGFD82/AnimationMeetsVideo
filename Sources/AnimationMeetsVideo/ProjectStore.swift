import CoreMedia
import Foundation

/// On-disk shape of `project.json`. Everything is referenced by stable ID,
/// times are exact rationals, and the encoder is deterministic, so saving an
/// unchanged project produces byte-identical output.
private struct ProjectFile: Codable {
    static let currentVersion = 1

    /// Exact rational time written as `"value/timescale s"` with no space,
    /// for example `"1001/24000s"`. A whole number of seconds may be written
    /// as `"5s"`.
    struct TimeEntry: Codable {
        var time: CMTime

        init(_ time: CMTime) {
            self.time = time
        }

        init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            guard text.hasSuffix("s") else {
                throw ProjectStoreError.invalidTime(text)
            }
            let body = text.dropLast()
            let parts = body.split(separator: "/", omittingEmptySubsequences: false)
            switch parts.count {
            case 1:
                guard let value = Int64(parts[0]) else { throw ProjectStoreError.invalidTime(text) }
                time = CMTime(value: value, timescale: 1)
            case 2:
                guard let value = Int64(parts[0]), let timescale = Int32(parts[1]), timescale > 0 else {
                    throw ProjectStoreError.invalidTime(text)
                }
                time = CMTime(value: value, timescale: timescale)
            default:
                throw ProjectStoreError.invalidTime(text)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode("\(time.value)/\(time.timescale)s")
        }
    }

    struct SourceEntry: Codable {
        enum Kind: String, Codable { case media, timeline }
        var kind: Kind
        var id: UUID
    }

    struct ClipEntry: Codable {
        var id: UUID
        var source: SourceEntry
        var startOffset: TimeEntry
        var trimStart: TimeEntry
        var trimEnd: TimeEntry
        var autoMatteEnabled: Bool
    }

    struct LayerEntry: Codable {
        var id: UUID
        var customName: String?
        var clips: [ClipEntry]
    }

    struct TimelineEntry: Codable {
        var id: UUID
        var name: String
        var width: Double
        var height: Double
        var frameRate: Double
        var colorSpace: String
        var layers: [LayerEntry]
    }

    struct RegionEntry: Codable {
        var id: UUID
        var start: TimeEntry
        var end: TimeEntry
        var value: Double
    }

    struct SceneEditsEntry: Codable {
        var sensitivity: Double?
        var regions: [RegionEntry]
        var manualCuts: [TimeEntry]
        var ignoredCuts: [TimeEntry]

        init(_ edits: SceneEdits) {
            sensitivity = edits.sensitivity
            regions = edits.regions.map { RegionEntry(id: $0.id, start: TimeEntry($0.start), end: TimeEntry($0.end), value: $0.value) }
            manualCuts = edits.manualCuts.map(TimeEntry.init)
            ignoredCuts = edits.ignoredCuts.map(TimeEntry.init)
        }

        var edits: SceneEdits {
            SceneEdits(
                sensitivity: sensitivity,
                regions: regions.map { SensitivityRegion(id: $0.id, start: $0.start.time, end: $0.end.time, value: $0.value) },
                manualCuts: manualCuts.map(\.time),
                ignoredCuts: ignoredCuts.map(\.time)
            )
        }
    }

    struct AssetEntry: Codable {
        var id: UUID
        var name: String
        /// Relative to the package when the file is inside it, otherwise an
        /// absolute path.
        var path: String
        /// Absent when the person hasn't edited the scene list.
        var sceneEdits: SceneEditsEntry?
    }

    var formatVersion: Int
    var id: UUID
    var name: String
    var rootTimelineID: UUID
    /// Absent in files written before scene detection; reads as balanced.
    var defaultSensitivity: Double?
    var assets: [AssetEntry]
    var timelines: [TimelineEntry]
}

private struct ProjectFileHeader: Decodable {
    var formatVersion: Int?
}

struct ProjectLoadResult {
    var project: EditingProject
    /// Media files referenced by the project that couldn't be opened; clips
    /// using them were dropped from the timelines.
    var missingMedia: [URL]
    /// Saved change scores found in `Reference/`, by asset ID. Assets with no
    /// entry haven't been analyzed yet.
    var changeScores: [UUID: ChangeScoreTrack] = [:]
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

    // MARK: Media consolidation

    /// Media that saving into `packageURL` would copy in: anything with a file
    /// outside the package. `preparePackage` must have run first so the
    /// package's volume can be compared.
    static func mediaToCopy(in project: EditingProject, into packageURL: URL) -> [MediaCopyCandidate] {
        let packageVolume = volumeInfo(for: packageURL)
        return project.clips.compactMap { clip in
            guard let url = clip.url, !isInside(url, package: packageURL),
                  FileManager.default.fileExists(atPath: url.path)
            else {
                return nil
            }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let sourceVolume = volumeInfo(for: url)
            let isClone = packageVolume.supportsCloning
                && sourceVolume.identifier != nil
                && sourceVolume.identifier?.isEqual(packageVolume.identifier) == true
            return MediaCopyCandidate(clipID: clip.id, sourceURL: url, byteCount: size, isClone: isClone)
        }
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
    /// ones that aren't saved yet.
    @discardableResult
    static func save(
        _ project: EditingProject,
        to packageURL: URL,
        copying: Set<UUID> = [],
        changeScores: [UUID: ChangeScoreTrack] = [:]
    ) async throws -> EditingProject {
        try preparePackage(at: packageURL)

        var project = project
        let mediaFolder = packageURL.appending(path: mediaFolderName, directoryHint: .isDirectory)
        for index in project.clips.indices {
            let clip = project.clips[index]
            guard copying.contains(clip.id), let source = clip.url, !isInside(source, package: packageURL) else { continue }
            let destination = uniqueDestination(for: source.lastPathComponent, in: mediaFolder)
            try FileManager.default.copyItem(at: source, to: destination)
            project.clips[index].url = destination
        }

        for (assetID, track) in changeScores where project.mediaClip(id: assetID) != nil {
            try writeChangeScores(track, for: assetID, in: packageURL)
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
                        clips: layer.clips.compactMap { clip in
                            guard let source = sourceEntry(for: clip.source) else { return nil }
                            return ProjectFile.ClipEntry(
                                id: clip.id,
                                source: source,
                                startOffset: ProjectFile.TimeEntry(clip.startOffset),
                                trimStart: ProjectFile.TimeEntry(clip.trimStart),
                                trimEnd: ProjectFile.TimeEntry(clip.trimEnd),
                                autoMatteEnabled: clip.autoMatteEnabled
                            )
                        }
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
            assets: urlClips.map { clip in
                ProjectFile.AssetEntry(
                    id: clip.id,
                    name: clip.name,
                    path: relativePath(for: clip.url!),
                    sceneEdits: clip.sceneEdits == SceneEdits() ? nil : ProjectFile.SceneEditsEntry(clip.sceneEdits)
                )
            },
            timelines: timelines
        )
    }

    // MARK: Load

    /// Loads a package. `importMedia` reads a media file's metadata; it is a
    /// parameter so tests can run without real footage.
    static func load(
        from packageURL: URL,
        importMedia: @Sendable (URL) async throws -> MediaClip = { try await MediaImporter.importClip(at: $0) }
    ) async throws -> ProjectLoadResult {
        try validatePackage(at: packageURL)
        let fileURL = packageURL.appending(path: projectFileName)
        let data = try Data(contentsOf: fileURL)

        let version = try JSONDecoder().decode(ProjectFileHeader.self, from: data).formatVersion
        guard let version, version >= 1 else {
            throw ProjectStoreError.unsupportedVersion(nil)
        }
        guard version <= ProjectFile.currentVersion else {
            throw ProjectStoreError.unsupportedVersion(version)
        }
        let file = try JSONDecoder().decode(ProjectFile.self, from: data)

        var importedClips: [UUID: MediaClip] = [:]
        var orderedIDs: [UUID] = []
        var missingMedia: [URL] = []
        for asset in file.assets {
            let url = asset.path.hasPrefix("/")
                ? URL(fileURLWithPath: asset.path)
                : packageURL.appending(path: asset.path)
            do {
                var clip = try await importMedia(url)
                clip.id = asset.id
                clip.name = asset.name
                clip.sceneEdits = asset.sceneEdits?.edits ?? SceneEdits()
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
                        clips: layerEntry.clips.compactMap { clipEntry in
                            guard let source = resolveSource(clipEntry.source) else { return nil }
                            return TimelineClip(
                                id: clipEntry.id,
                                source: source,
                                startOffset: clipEntry.startOffset.time,
                                trimStart: clipEntry.trimStart.time,
                                trimEnd: clipEntry.trimEnd.time,
                                autoMatteEnabled: clipEntry.autoMatteEnabled
                            )
                        }
                    )
                },
                frameSize: CGSize(width: entry.width, height: entry.height),
                frameRate: entry.frameRate,
                colorSpace: ProjectColorSpace(rawValue: entry.colorSpace) ?? .rec709
            )
        }

        guard let first = timelines.first else {
            throw ProjectStoreError.noTimelines
        }
        let rootID = timelineIDs.contains(file.rootTimelineID) ? file.rootTimelineID : first.id

        let project = EditingProject(
            id: file.id,
            name: file.name,
            clips: orderedIDs.compactMap { importedClips[$0] },
            timelines: timelines,
            rootTimelineID: rootID,
            defaultSensitivity: file.defaultSensitivity ?? SceneDetector.balancedSensitivity
        )
        var scores: [UUID: ChangeScoreTrack] = [:]
        for id in orderedIDs {
            scores[id] = readChangeScores(for: id, in: packageURL)
        }
        return ProjectLoadResult(project: project, missingMedia: missingMedia, changeScores: scores)
    }
}

enum ProjectStoreError: LocalizedError {
    case noTimelines
    case notAProject(String)
    case unsupportedVersion(Int?)
    case invalidTime(String)
    case locked(String?)

    var errorDescription: String? {
        switch self {
        case .noTimelines:
            "The project file doesn't contain any timelines."
        case .notAProject(let name):
            "“\(name)” isn't an Animation Meets Video project (no project.json inside)."
        case .unsupportedVersion(let version):
            if let version {
                "This project was saved by a newer version of the app (format version \(version))."
            } else {
                "This project file has no supported format version."
            }
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
