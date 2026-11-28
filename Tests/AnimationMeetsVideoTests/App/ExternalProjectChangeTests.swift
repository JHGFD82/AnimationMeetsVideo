import Foundation
import Testing
@testable import AnimationMeetsVideo

/// `project.json` changed outside the app while it is open
/// (`ProjectSession.checkForExternalProjectChange`).
@MainActor
@Suite(.serialized) struct ExternalProjectChangeTests {
    /// A file that changes clips the Motion Designer holds can't be taken
    /// under its locks. It waits, still unread, rather than being marked
    /// seen with the project left as it was, which let the next save
    /// write over it.
    @Test func aChangeToHeldClipsWaitsUntilTheyAreLetGo() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "amv-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Cut.amv", directoryHint: .isDirectory)
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let made = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(made)
        try await ProjectStore.save(project, to: url)

        let session = ProjectSession()
        #expect(await session.open(url))
        defer { session.close() }
        let key = session.projectState.lock([shape.clipID], in: timelineID)

        var outside = session.project
        outside.editClip(shape.clipID, in: timelineID) { $0.enabled = false }
        try await ProjectStore.save(outside, to: url)
        #expect(session.fileMonitor.pendingChange() != nil)
        func enabled() -> Bool? { session.project.clipAndLayer(shape.clipID, in: timelineID)?.clip.enabled }

        await session.checkForExternalProjectChange()
        #expect(enabled() == true)
        #expect(!session.hasUnsavedChanges)
        #expect(session.fileMonitor.pendingChange() != nil)

        // Let go, the file is taken.
        session.projectState.unlock(key)
        await session.checkForExternalProjectChange()
        #expect(enabled() == false)
        #expect(!session.hasUnsavedChanges)
        #expect(session.fileMonitor.pendingChange() == nil)
    }

    /// An open project with one shape clip, saved, and its session.
    @MainActor private struct Opened {
        let folder: URL
        let url: URL
        let session: ProjectSession
        let timelineID: UUID
        let clipID: UUID

        init() async throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "amv-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appending(path: "Cut.amv", directoryHint: .isDirectory)
            var project = EditingProject.empty
            timelineID = project.rootTimelineID
            let made = project.addShapeLayer(.rectangle, to: timelineID)
            clipID = try #require(made).clipID
            try await ProjectStore.save(project, to: url)
            session = ProjectSession()
            #expect(await session.open(url))
        }

        func enabledOnScreen() -> Bool? { session.project.clipAndLayer(clipID, in: timelineID)?.clip.enabled }

        func enabledOnDisk() async throws -> Bool? {
            try await ProjectStore.load(from: url).project.clipAndLayer(clipID, in: timelineID)?.clip.enabled
        }

        /// Another program turning the clip off in the file.
        func editOutside() async throws {
            var outside = session.project
            outside.editClip(clipID, in: timelineID) { $0.enabled = false }
            try await ProjectStore.save(outside, to: url)
        }

        func cleanUp() {
            session.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The app saves half a second after an edit but looks at the file
    /// every two seconds: a save in between wrote over what another
    /// program had just written. It takes the change first.
    @Test func aSaveTakesAnOutsideEditBeforeWriting() async throws {
        let opened = try await Opened()
        defer { opened.cleanUp() }
        try await opened.editOutside()
        #expect(await opened.session.save(quietly: true))
        #expect(opened.enabledOnScreen() == false)
        #expect(try await opened.enabledOnDisk() == false)
        #expect(opened.session.fileMonitor.pendingChange() == nil)
    }

    /// A file this version can't read (another format, say) is told
    /// about once and never saved over without asking: marked seen, it
    /// was written over by the next automatic save.
    @Test func aFileThatCantBeReadIsntSavedOverUnasked() async throws {
        let opened = try await Opened()
        defer { opened.cleanUp() }
        final class Said { var alerts: [String] = []; var asked = 0; var answer = false }
        let said = Said()
        opened.session.presentAlert = { title, _ in said.alerts.append(title) }
        opened.session.confirmSavingOver = { _ in said.asked += 1; return said.answer }
        let other = Data(#"{"formatVersion": 3}"#.utf8)
        try other.write(to: opened.url.appending(path: ProjectStore.projectFileName))

        // Read twice, as a file being written may be, before it is told.
        await opened.session.checkForExternalProjectChange()
        #expect(said.alerts.isEmpty)
        await opened.session.checkForExternalProjectChange()
        #expect(said.alerts.count == 1)
        await opened.session.checkForExternalProjectChange()
        #expect(said.alerts.count == 1)

        #expect(!(await opened.session.save(quietly: true)))
        #expect(try Data(contentsOf: opened.url.appending(path: ProjectStore.projectFileName)) == other)
        #expect(!(await opened.session.save()))
        #expect(said.asked == 1)
        #expect(try Data(contentsOf: opened.url.appending(path: ProjectStore.projectFileName)) == other)
        said.answer = true
        #expect(await opened.session.save())
        #expect(try await opened.enabledOnDisk() == true)
    }

    /// Caught halfway through another program writing it, the file is
    /// read again at the next check and taken, with nothing said.
    @Test func aFileReadHalfWrittenIsReadAgain() async throws {
        let opened = try await Opened()
        defer { opened.cleanUp() }
        final class Said { var alerts: [String] = [] }
        let said = Said()
        opened.session.presentAlert = { title, _ in said.alerts.append(title) }
        let file = opened.url.appending(path: ProjectStore.projectFileName)
        let whole = try Data(contentsOf: file)
        try whole.prefix(whole.count / 2).write(to: file)
        await opened.session.checkForExternalProjectChange()
        try await opened.editOutside()
        await opened.session.checkForExternalProjectChange()
        #expect(said.alerts.isEmpty)
        #expect(opened.enabledOnScreen() == false)
    }
}
