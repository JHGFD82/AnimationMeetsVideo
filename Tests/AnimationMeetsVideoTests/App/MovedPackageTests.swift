import CoreMedia
import Foundation
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
}
