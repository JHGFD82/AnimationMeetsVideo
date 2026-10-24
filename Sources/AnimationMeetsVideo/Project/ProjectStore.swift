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
