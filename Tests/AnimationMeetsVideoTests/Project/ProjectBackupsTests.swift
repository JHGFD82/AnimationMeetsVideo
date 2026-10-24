import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A saved project whose media was copied into its package, with some
/// reference data beside it, and a folder for backups.
private struct BackupSandbox {
    let root: URL
    let packageURL: URL
    let location: URL
    let project: EditingProject
    let assetID: UUID

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "amv-backup-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let footage = root.appending(path: "footage.mov")
        try Data("not really video".utf8).write(to: footage)
        packageURL = root.appending(path: "Test.amv", directoryHint: .isDirectory)
        location = root.appending(path: "Backups", directoryHint: .isDirectory)

        var project = EditingProject.empty
        project.name = "Test"
        let asset = MediaClip(
            name: "footage.mov", kind: .video, url: footage,
            duration: CMTime(seconds: 10, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
        _ = project.importClip(asset, intoTimeline: project.rootTimelineID)
        assetID = asset.id
        try ProjectStore.preparePackage(at: packageURL)
        self.project = try await ProjectStore.save(project, to: packageURL, copying: [asset.id])
        let reference = packageURL.appending(path: "\(ProjectStore.referenceFolderName)/\(asset.id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        try Data("pictures".utf8).write(to: reference.appending(path: "thumbnails.bin"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite struct ProjectBackupsTests {
    @Test func aBackupHoldsWhatTheProjectNeedsToOpenOnItsOwn() async throws {
        let sandbox = try await BackupSandbox()
        defer { sandbox.cleanUp() }
        let backup = try ProjectBackups.write(sandbox.project, packageURL: sandbox.packageURL, to: sandbox.location)

        #expect(backup.pathExtension == ProjectBackups.fileExtension)
        #expect(backup.deletingLastPathComponent().lastPathComponent == "Test")
        let fileManager = FileManager.default
        #expect(fileManager.fileExists(atPath: backup.appending(path: ProjectStore.projectFileName).path))
        #expect(fileManager.fileExists(atPath: backup.appending(path: "Media/footage.mov").path))
        #expect(fileManager.fileExists(atPath: backup.appending(path: "Reference/\(sandbox.assetID.uuidString)/thumbnails.bin").path))
        let info = try ProjectBackups.readInfo(of: backup)
        #expect(info.projectName == "Test")
        #expect(info.originalProject == sandbox.packageURL.path)
    }

    @Test func onlyTheNewestAreKept() async throws {
        let sandbox = try await BackupSandbox()
        defer { sandbox.cleanUp() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for minute in 0..<(ProjectBackups.kept + 2) {
            try ProjectBackups.write(
                sandbox.project, packageURL: sandbox.packageURL, to: sandbox.location,
                now: start.addingTimeInterval(Double(minute) * 60)
            )
        }
        let folder = ProjectBackups.folder(forProjectNamed: "Test", in: sandbox.location)
        let kept = ProjectBackups.backups(in: folder)
        #expect(kept.count == ProjectBackups.kept)
        // The two oldest went.
        let newestFirstMinute = try ProjectBackups.readInfo(of: try #require(kept.first)).createdAt
        #expect(newestFirstMinute == start.addingTimeInterval(120))
    }

    @Test func restoringMakesANewProjectAndLeavesTheOriginal() async throws {
        let sandbox = try await BackupSandbox()
        defer { sandbox.cleanUp() }
        let originalJSON = try Data(contentsOf: sandbox.packageURL.appending(path: ProjectStore.projectFileName))
        let backup = try ProjectBackups.write(sandbox.project, packageURL: sandbox.packageURL, to: sandbox.location)
        let info = try ProjectBackups.readInfo(of: backup)
        #expect(ProjectBackups.defaultRestoreFolder(for: info)?.standardizedFileURL.path == sandbox.root.standardizedFileURL.path)

        let restored = try ProjectBackups.restore(backup, into: sandbox.root)
        #expect(restored.lastPathComponent.hasPrefix("Test from backup "))
        #expect(restored.pathExtension == ProjectStore.packageExtension)
        #expect(!FileManager.default.fileExists(atPath: restored.appending(path: ProjectBackups.infoFileName).path))
        #expect(try Data(contentsOf: sandbox.packageURL.appending(path: ProjectStore.projectFileName)) == originalJSON)

        // Fake footage: found when the file is there, as the real importer
        // would read it.
        let loaded = try await ProjectStore.load(from: restored) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
            return MediaClip(
                name: url.lastPathComponent, kind: .video, url: url,
                duration: CMTime(seconds: 10, preferredTimescale: 600),
                frameRate: 24, colorSpace: .rec709, codecName: "Stub"
            )
        }
        #expect(loaded.project.name == restored.deletingPathExtension().lastPathComponent)
        #expect(loaded.missingMedia.isEmpty)
        let media = try #require(loaded.project.clips.first?.url)
        #expect(ProjectStore.isInside(media, package: restored))
    }
}
