import Foundation
import UniformTypeIdentifiers

/// Backups of projects kept outside them, in a folder of the person's
/// choosing, as Final Cut Pro keeps library backups: if a project's
/// package is deleted, damaged, or on a disk that fails, a backup brings
/// it back.
///
/// A backup is an `.amvbackup` package holding what a project needs to be
/// opened on its own: its `project.json`, its `Media/` and its
/// `Reference/` (the original files' pictures, sound and scores, which
/// can't be made again once a file is replaced), and `backup.json`, which
/// says where the project was and when this was taken. Media the project
/// refers to in place stays where it is and isn't copied. The cache and
/// the package's own autosaves are left out; they can be made again.
///
/// Each file is copied from the previous backup when it is unchanged, so
/// on an APFS volume it is a clone that takes no space: only the first
/// backup on a disk copies the project's media for real, and later ones
/// cost what changed. A backup on the project's own volume costs nothing,
/// but doesn't survive that disk failing.
///
/// Opening a backup never touches the project it came from: it becomes a
/// new project beside it, "Name from backup 2026-10-24 14.30".
enum ProjectBackups {
    static let fileExtension = "amvbackup"
    /// The backup type the app bundle declares (`Packaging/Info.plist`).
    static let typeIdentifier = "com.jhgfd.animationmeetsvideo.backup"
    static let type: UTType = UTType(typeIdentifier)
        ?? UTType(filenameExtension: fileExtension, conformingTo: .package)
        ?? .package
    static let infoFileName = "backup.json"
    /// Backups kept per project; the oldest go first.
    static let kept = 10

    /// What a backup says about itself.
    struct Info: Codable, Equatable {
        /// The project package it was taken of.
        var originalProject: String
        var projectName: String
        /// When it was taken, as ISO 8601 text, so the file reads plainly.
        var created: String
        var formatVersion = 1

        init(originalProject: String, projectName: String, createdAt: Date) {
            self.originalProject = originalProject
            self.projectName = projectName
            created = createdAt.ISO8601Format()
        }

        var createdAt: Date {
            (try? Date(created, strategy: .iso8601)) ?? .distantPast
        }
    }

    /// Where backups go unless the person chose a folder.
    static var defaultLocation: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appending(path: "Animation Meets Video Backups", directoryHint: .isDirectory)
    }

    /// The folder in `location` a project's backups are kept in, one per
    /// project name.
    static func folder(forProjectNamed name: String, in location: URL) -> URL {
        location.appending(path: name.isEmpty ? "Untitled" : name, directoryHint: .isDirectory)
    }

    /// Where to look for a project's backups: its folder in `location`,
    /// or `location` itself before the project has one (or after it was
    /// renamed, when its backups are under the old name).
    static func folderToBrowse(forProjectNamed name: String, in location: URL) -> URL {
        let folder = folder(forProjectNamed: name, in: location)
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue ? folder : location
    }

    // MARK: - Writing

    /// Writes a backup of `project`, saved in `packageURL`, into its folder
    /// in `location`, and deletes the oldest past `kept`. Returns the backup.
    @discardableResult
    static func write(
        _ project: EditingProject, packageURL: URL, to location: URL, now: Date = Date()
    ) throws -> URL {
        let fileManager = FileManager.default
        let folder = folder(forProjectNamed: project.name, in: location)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = backups(in: folder).last

        let name = "\(project.name) \(stamp(now)).\(fileExtension)"
        let destination = uniqueURL(folder.appending(path: name, directoryHint: .isDirectory))
        // Written beside it under a name no listing takes for a backup, and
        // renamed into place once whole, so a backup cut off half-way is
        // never offered.
        let partial = folder.appending(path: ".\(UUID().uuidString).partial", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            try ProjectStore.encode(project, packageURL: packageURL)
                .write(to: partial.appending(path: ProjectStore.projectFileName), options: .atomic)
            for subfolder in [ProjectStore.mediaFolderName, ProjectStore.referenceFolderName] {
                try copyTree(subfolder, of: packageURL, into: partial, reusing: previous)
            }
            let info = Info(originalProject: packageURL.path, projectName: project.name, createdAt: now)
            try JSONFile.encode(info).write(to: partial.appending(path: infoFileName), options: .atomic)
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }

        for old in backups(in: folder).dropLast(kept) {
            try? fileManager.removeItem(at: old)
        }
        return destination
    }

    /// The backups in `folder`, oldest first (their names sort by date).
    static func backups(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasSuffix(".\(fileExtension)") && !$0.hasPrefix(".") }
            .sorted()
            .map { folder.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// Copies `subfolder` of the package into the backup, each file from
    /// the previous backup instead when it holds the same file (same size
    /// and modification date), which on APFS is a clone that takes no space.
    private static func copyTree(_ subfolder: String, of packageURL: URL, into backup: URL, reusing previous: URL?) throws {
        let fileManager = FileManager.default
        let source = packageURL.appending(path: subfolder, directoryHint: .isDirectory)
        guard let walker = fileManager.enumerator(
            at: source, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, !file.lastPathComponent.hasSuffix(".partial") else { continue }
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            let relative = subfolder + "/" + path.dropFirst(sourcePath.count + 1)
            let target = backup.appending(path: relative)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let previous, let earlier = sameFile(previous.appending(path: relative), as: values) {
                try fileManager.copyItem(at: earlier, to: target)
            } else {
                try fileManager.copyItem(at: file, to: target)
            }
        }
    }

    /// `candidate`, when it is the same file as one with `values`.
    private static func sameFile(_ candidate: URL, as values: URLResourceValues) -> URL? {
        guard let other = try? candidate.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              other.fileSize == values.fileSize, other.contentModificationDate == values.contentModificationDate
        else { return nil }
        return candidate
    }

    // MARK: - Restoring

    static func readInfo(of backup: URL) throws -> Info {
        try JSONDecoder().decode(Info.self, from: Data(contentsOf: backup.appending(path: infoFileName)))
    }

    /// The name a restored project gets: "Name from backup 2026-10-24 14.30".
    static func restoredName(for info: Info) -> String {
        "\(info.projectName) from backup \(stamp(info.createdAt, seconds: false))"
    }

    /// Where a restored project goes when nothing else is asked: beside the
    /// project the backup was taken of, if that folder is still there.
    static func defaultRestoreFolder(for info: Info) -> URL? {
        let folder = URL(fileURLWithPath: info.originalProject).deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: folder.path) ? folder : nil
    }

    /// Makes the backup a new project in `folder`, named for the backup so
    /// it is never mistaken for the original, which is left untouched.
    /// Returns the new package.
    static func restore(_ backup: URL, into folder: URL) throws -> URL {
        let fileManager = FileManager.default
        let info = try readInfo(of: backup)
        let name = restoredName(for: info)
        let destination = uniqueURL(folder.appending(path: "\(name).\(ProjectStore.packageExtension)", directoryHint: .isDirectory))
        try fileManager.copyItem(at: backup, to: destination)
        do {
            try fileManager.removeItem(at: destination.appending(path: infoFileName))
            try makeNewProject(in: destination, named: destination.deletingPathExtension().lastPathComponent)
            try ProjectStore.preparePackage(at: destination)
            ProjectStore.markAsPackage(destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// Sets the name in a package's `project.json` and gives it an ID of
    /// its own, so the restored project and the original are told apart
    /// by ID as well as by place; the rest is untouched and is written in
    /// the app's own form at its next save.
    private static func makeNewProject(in packageURL: URL, named name: String) throws {
        let file = packageURL.appending(path: ProjectStore.projectFileName)
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { return }
        object["name"] = name
        object["id"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)
    }

    // MARK: - Names

    private static func stamp(_ date: Date, seconds: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = seconds ? "yyyy-MM-dd HH.mm.ss" : "yyyy-MM-dd HH.mm"
        return formatter.string(from: date)
    }

    /// `url`, or with " 2", " 3" and on before its extension when taken.
    private static func uniqueURL(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var number = 2
        while true {
            let candidate = url.deletingLastPathComponent().appending(path: "\(base) \(number).\(ext)", directoryHint: .isDirectory)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }
}
