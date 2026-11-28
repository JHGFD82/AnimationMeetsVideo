import CoreMedia
import Foundation
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// The open project's package renamed, moved or deleted in the Finder
/// (code-review-notes.md, F67). Nothing noticed: the next save made a
/// second package where it had been, unlocked, whose media paths led
/// nowhere.
@MainActor
@Suite(.serialized) struct MovedPackageTests {
    /// An open project whose one asset's file is in its package's Media.
    @MainActor private struct Opened {
        let folder: URL
        let url: URL
        let session: ProjectSession
        let mediaID: UUID

        init() async throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "amv-moved-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appending(path: "Cut.amv", directoryHint: .isDirectory)
            try ProjectStore.preparePackage(at: url)
            let file = url.appending(path: "\(ProjectStore.mediaFolderName)/take.wav")
            try Data("not really sound".utf8).write(to: file)
            var project = EditingProject.empty
            let clip = MediaClip(
                name: "take", kind: .audio, url: file, duration: CMTime(value: 1, timescale: 1),
                frameRate: 0, colorSpace: .rec709, codecName: "PCM", hasAudio: true
            )
            project.addMedia(clip)
            mediaID = clip.id
            try await ProjectStore.save(project, to: url)
            session = ProjectSession()
            #expect(await session.open(url))
        }

        /// An edit, so there is something to save.
        func edit() {
            session.project.name = "Edited \(UUID().uuidString.prefix(4))"
        }

        func close() {
            session.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func path(_ url: URL?) -> String? { url?.standardizedFileURL.resolvingSymlinksInPath().path }

    @Test func aSaveAfterThePackageIsRenamedGoesWhereItWent() async throws {
        let opened = try await Opened()
        defer { opened.close() }
        let renamed = opened.folder.appending(path: "Renamed.amv", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: opened.url, to: renamed)
        guard case .moved(let found) = opened.session.packagePlace() else {
            Issue.record("The move wasn't seen: \(opened.session.packagePlace())")
            return
        }
        #expect(path(found) == path(renamed))
        opened.edit()

        #expect(await opened.session.save())
        // No second package where it was.
        #expect(!FileManager.default.fileExists(atPath: opened.url.path))
        #expect(path(opened.session.projectURL) == path(renamed))
        // Its media are named where they are now, in the file and on screen.
        let file = renamed.appending(path: "\(ProjectStore.mediaFolderName)/take.wav")
        let loaded = try await ProjectStore.load(from: renamed).project
        #expect(path(loaded.mediaClip(id: opened.mediaID)?.url) == path(file))
        #expect(path(opened.session.project.mediaClip(id: opened.mediaID)?.url) == path(file))
        #expect(loaded.name == opened.session.project.name)
        #expect(!opened.session.hasUnsavedChanges)
        // Still locked by this window: another can't take it.
        #expect(throws: ProjectStoreError.self) { _ = try ProjectLock.acquire(at: renamed) }
    }

    @Test func nothingIsWrittenWhereADeletedPackageWas() async throws {
        let opened = try await Opened()
        defer { opened.close() }
        try FileManager.default.removeItem(at: opened.url)
        #expect(opened.session.packagePlace() == .gone)
        opened.edit()

        #expect(await opened.session.save(quietly: true) == false)
        await opened.session.autosave()
        await opened.session.backUpIfDue()
        await opened.session.checkForExternalProjectChange()
        #expect(!FileManager.default.fileExists(atPath: opened.url.path))
        #expect(opened.session.hasUnsavedChanges)
    }

    /// Writes told the package's place before it moved, and made after
    /// (code-review-notes.md, F123): each made its folders with
    /// intermediate directories, so the package came back where it had
    /// been. Each now fails, and nothing is made there.
    @Test func writesAfterAMoveMakeNothingWhereThePackageWas() async throws {
        let opened = try await Opened()
        defer { opened.close() }
        let outside = try AudioMixSupport.tone(seconds: 0.1)
        defer { try? FileManager.default.removeItem(at: outside) }
        let renamed = opened.folder.appending(path: "Renamed.amv", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: opened.url, to: renamed)
        let old = opened.url
        let id = UUID()

        #expect(throws: PackageNotFound.self) { _ = try ProjectStore.copyIntoPackage(outside, packageURL: old) }
        #expect(throws: PackageNotFound.self) {
            try ProjectStore.writeChangeScores(ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 0]), for: id, in: old)
        }
        #expect(throws: PackageNotFound.self) { try ProjectStore.writeBackup(of: opened.session.project, in: old) }
        #expect(throws: PackageNotFound.self) { _ = try RenderCache(packageURL: old).partialURL(for: "key") }
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    /// A save that checked where the package was and then wrote, with the
    /// package moved in between, made it again where it had been: no
    /// package is made by a save into the one open, and the save fails.
    @Test func aSaveMovedUnderBetweenItsCheckAndItsWriteMakesNoPackage() async throws {
        let opened = try await Opened()
        defer { opened.close() }
        let renamed = opened.folder.appending(path: "Renamed.amv", directoryHint: .isDirectory)
        // As the session's check found it, then moved before the write.
        let checked = opened.url
        try FileManager.default.moveItem(at: opened.url, to: renamed)

        await #expect(throws: PackageNotFound.self) {
            try await ProjectStore.save(opened.session.project, to: checked, previousPackageURL: checked)
        }
        #expect(!FileManager.default.fileExists(atPath: checked.path))
        // Saving somewhere new still makes the package.
        let elsewhere = opened.folder.appending(path: "Copy.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(opened.session.project, to: elsewhere, previousPackageURL: renamed)
        #expect(FileManager.default.fileExists(atPath: elsewhere.appending(path: ProjectStore.projectFileName).path))
    }

    /// An import given the package's place from before a move, unnoticed
    /// yet, copied the file to the old place, and the clip then named it
    /// there; once the move was followed the clip was offline and its
    /// file outside the package. It now follows the move first.
    @Test func anImportAfterAnUnnoticedMoveCopiesIntoThePackageWhereItIs() async throws {
        let opened = try await Opened()
        defer { opened.close() }
        let outside = try AudioMixSupport.tone(seconds: 0.1)
        defer { try? FileManager.default.removeItem(at: outside) }
        let renamed = opened.folder.appending(path: "Renamed.amv", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: opened.url, to: renamed)
        let session = opened.session
        let binding = Binding(get: { session.project }, set: { session.project = $0 })

        var errors: [String] = []
        let imported = await MediaImportFlow.importFiles(
            [outside], copying: [outside], packageURL: opened.url, project: binding, onError: { errors.append($0) }
        )
        #expect(errors.isEmpty)
        let clip = try #require(imported.first)
        let media = renamed.appending(path: ProjectStore.mediaFolderName, directoryHint: .isDirectory)
        #expect(path(clip.url?.deletingLastPathComponent()) == path(media))
        #expect(clip.url.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(!FileManager.default.fileExists(atPath: opened.url.path))
        #expect(path(session.projectURL) == path(renamed))
        // The asset already there is named where it is now too.
        #expect(path(session.project.mediaClip(id: opened.mediaID)?.url?.deletingLastPathComponent()) == path(media))
    }
}
