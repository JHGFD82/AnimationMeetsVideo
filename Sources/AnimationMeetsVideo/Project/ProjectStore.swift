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
        /// `"video"` or `"audio"` once a video's sound is detached; absent
        /// while the clip plays everything its file has.
        var streams: String?
        var transitionIn: TransitionEntry?
        var transitionOut: TransitionEntry?
    }

    /// A transition at one end of a clip. `kind` is a `TransitionKind`
    /// name such as `"crossDissolve"`; an unknown kind is dropped on load.
    struct TransitionEntry: Codable {
        var kind: String
        var duration: TimeEntry

        init(_ transition: ClipTransition) {
            kind = transition.kind.rawValue
            duration = TimeEntry(transition.duration)
        }

        var transition: ClipTransition? {
            guard let kind = TransitionKind(rawValue: kind), duration.time > .zero else { return nil }
            return ClipTransition(kind: kind, duration: duration.time)
        }
    }

    /// One keyframe. Vector values are written as `[x, y]`.
    struct KeyframeEntry<Value: Codable>: Codable {
        var time: TimeEntry
        var value: Value
    }

    /// A property's value, or its keyframes when animated.
    struct PropertyEntry<Value: Codable>: Codable {
        var value: Value?
        var keyframes: [KeyframeEntry<Value>]?

        init<V: Interpolatable>(_ property: AnimatedValue<V>, encode: (V) -> Value) {
            if property.isAnimated {
                keyframes = property.keyframes.map { KeyframeEntry(time: TimeEntry($0.time), value: encode($0.value)) }
            } else {
                value = encode(property.value)
            }
        }

        func property<V: Interpolatable>(default fallback: V, decode: (Value) -> V?) -> AnimatedValue<V> {
            let frames = (keyframes ?? []).compactMap { entry in
                decode(entry.value).map { Keyframe(time: entry.time.time, value: $0) }
            }
            return AnimatedValue(value.flatMap(decode) ?? frames.first?.value ?? fallback, keyframes: frames)
        }
    }

    /// Each property is absent while it has its default value.
    struct TransformEntry: Codable {
        /// Offset of the layer's center from the frame's center, in pixels.
        var position: PropertyEntry<[Double]>?
        /// Percent.
        var scale: PropertyEntry<[Double]>?
        /// Degrees clockwise.
        var rotation: PropertyEntry<Double>?
        /// Percent.
        var opacity: PropertyEntry<Double>?
        /// Absent while linked.
        var scaleLinked: Bool?

        init?(_ transform: LayerTransform) {
            guard transform != .identity else { return nil }
            let identity = LayerTransform.identity
            let vector: (Vector2) -> [Double] = { [$0.x, $0.y] }
            position = transform.position == identity.position ? nil : PropertyEntry(transform.position, encode: vector)
            scale = transform.scale == identity.scale ? nil : PropertyEntry(transform.scale, encode: vector)
            rotation = transform.rotation == identity.rotation ? nil : PropertyEntry(transform.rotation) { $0 }
            opacity = transform.opacity == identity.opacity ? nil : PropertyEntry(transform.opacity) { $0 }
            scaleLinked = transform.scaleLinked ? nil : false
        }

        var transform: LayerTransform {
            let identity = LayerTransform.identity
            let vector: ([Double]) -> Vector2? = { $0.count == 2 ? Vector2(x: $0[0], y: $0[1]) : nil }
            let number: (Double) -> Double? = { $0 }
            return LayerTransform(
                position: position?.property(default: identity.position.value, decode: vector) ?? identity.position,
                scale: scale?.property(default: identity.scale.value, decode: vector) ?? identity.scale,
                rotation: rotation?.property(default: identity.rotation.value, decode: number) ?? identity.rotation,
                opacity: opacity?.property(default: identity.opacity.value, decode: number) ?? identity.opacity,
                scaleLinked: scaleLinked ?? true
            )
        }
    }

    struct LayerEntry: Codable {
        var id: UUID
        var customName: String?
        var clips: [ClipEntry]
        /// Absent while the layer is untransformed.
        var transform: TransformEntry?
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
        /// Absent when the file is aligned with the original.
        var alignmentOffset: TimeEntry?
        /// Absent when the asset has never been replaced.
        var previousPaths: [String]?
        /// Absent in files written before replacement existed.
        var fileStamp: FileStamp?
        /// Absent unless the original was forgotten.
        var referenceForgotten: Bool?
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
        let mediaFolder = packageURL.appending(path: mediaFolderName, directoryHint: .isDirectory)
        for index in project.clips.indices {
            let clip = project.clips[index]
            guard copying.contains(clip.id), let source = clip.url, !isInside(source, package: packageURL) else { continue }
            let destination = uniqueDestination(for: source.lastPathComponent, in: mediaFolder)
            try FileManager.default.copyItem(at: source, to: destination)
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
                                autoMatteEnabled: clip.autoMatteEnabled,
                                streams: clip.streams == .videoAndAudio ? nil : clip.streams.rawValue,
                                transitionIn: clip.transitionIn.map(ProjectFile.TransitionEntry.init),
                                transitionOut: clip.transitionOut.map(ProjectFile.TransitionEntry.init)
                            )
                        },
                        transform: ProjectFile.TransformEntry(layer.transform)
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
                                transitionOut: clipEntry.transitionOut?.transition
                            )
                        },
                        transform: layerEntry.transform?.transform ?? .identity
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
