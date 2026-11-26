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
}
