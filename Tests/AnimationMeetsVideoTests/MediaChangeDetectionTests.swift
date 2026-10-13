import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
@Suite struct MediaChangeDetectionTests {
    private func makeProject(file: URL) -> (project: EditingProject, assetID: UUID) {
        var project = EditingProject.empty
        var media = MediaClip(
            name: "m", kind: .video, url: file,
            duration: CMTime(seconds: 10, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        media.acceptedStamp = FileStamp(url: file)
        _ = project.importClip(media, intoTimeline: project.rootTimelineID)
        return (project, media.id)
    }

    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func anUnchangedFileIsNotFlagged() throws {
        let file = try tempFile("one")
        defer { try? FileManager.default.removeItem(at: file) }
        let (project, _) = makeProject(file: file)
        let controller = MediaReplacementController()

        controller.checkForChanges(in: project)

        #expect(controller.changedMedia.isEmpty)
        #expect(controller.notice == nil)
    }

    @Test func aChangedFileIsFlaggedOnceAndUnflaggedWhenItMatchesAgain() throws {
        let file = try tempFile("one")
        defer { try? FileManager.default.removeItem(at: file) }
        let (project, assetID) = makeProject(file: file)
        let controller = MediaReplacementController()

        try Data("a longer replacement".utf8).write(to: file)
        controller.checkForChanges(in: project)
        #expect(controller.changedMedia == [assetID])
        #expect(controller.notice != nil)

        // A second look doesn't announce it again.
        controller.notice = nil
        controller.checkForChanges(in: project)
        #expect(controller.notice == nil)

        try Data("one".utf8).write(to: file)
        var restored = project
        restored.setAcceptedStamp(FileStamp(url: file), forAsset: assetID)
        controller.checkForChanges(in: restored)
        #expect(controller.changedMedia.isEmpty)
    }

    @Test func aMissingFileIsLeftAlone() throws {
        let file = try tempFile("one")
        let (project, _) = makeProject(file: file)
        try FileManager.default.removeItem(at: file)
        let controller = MediaReplacementController()

        controller.checkForChanges(in: project)

        #expect(controller.changedMedia.isEmpty)
    }
}

private extension EditingProject {
    mutating func setAcceptedStamp(_ stamp: FileStamp?, forAsset id: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].acceptedStamp = stamp
    }
}
