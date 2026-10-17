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

    @Test func anUnchangedFileIsNotFlagged() async throws {
        let file = try tempFile("one")
        defer { try? FileManager.default.removeItem(at: file) }
        let (project, _) = makeProject(file: file)
        let controller = MediaReplacementController()

        await controller.checkForChanges { project }

        #expect(controller.changedMedia.isEmpty)
        #expect(controller.notice == nil)
    }

    @Test func aChangedFileIsFlaggedOnceAndUnflaggedWhenItMatchesAgain() async throws {
        let file = try tempFile("one")
        defer { try? FileManager.default.removeItem(at: file) }
        let (project, assetID) = makeProject(file: file)
        let controller = MediaReplacementController()

        try Data("a longer replacement".utf8).write(to: file)
        await controller.checkForChanges { project }
        #expect(controller.changedMedia == [assetID])
        #expect(controller.notice != nil)

        // A second look doesn't announce it again.
        controller.notice = nil
        await controller.checkForChanges { project }
        #expect(controller.notice == nil)

        try Data("one".utf8).write(to: file)
        var restored = project
        restored.setAcceptedStamp(FileStamp(url: file), forAsset: assetID)
        await controller.checkForChanges { restored }
        #expect(controller.changedMedia.isEmpty)
    }

    @Test func aNoticeWaitsUntilTheSheetHasClosed() async throws {
        let file = try tempFile("one")
        defer { try? FileManager.default.removeItem(at: file) }
        let (project, _) = makeProject(file: file)
        let controller = MediaReplacementController()

        controller.sheetDidAppear()
        try Data("a longer replacement".utf8).write(to: file)
        await controller.checkForChanges { project }
        #expect(controller.notice == nil)

        controller.sheetDidDismiss()
        #expect(controller.notice != nil)
    }

    @Test func aMissingFileIsReportedOnceAndNotFlaggedAsChanged() async throws {
        let file = try tempFile("one")
        defer { try? FileManager.default.removeItem(at: file) }
        let (project, assetID) = makeProject(file: file)
        let controller = MediaReplacementController()
        try Data("a longer replacement".utf8).write(to: file)
        await controller.checkForChanges { project }
        controller.notice = nil

        try FileManager.default.removeItem(at: file)
        await controller.checkForChanges { project }
        #expect(controller.changedMedia.isEmpty)
        #expect(controller.missingMedia == [assetID])
        #expect(controller.notice?.title == "Media Missing")

        controller.notice = nil
        await controller.checkForChanges { project }
        #expect(controller.notice == nil)

        try Data("one".utf8).write(to: file)
        var restored = project
        restored.setAcceptedStamp(FileStamp(url: file), forAsset: assetID)
        await controller.checkForChanges { restored }
        #expect(controller.missingMedia.isEmpty)
        #expect(controller.changedMedia.isEmpty)
    }

    @Test func readingsOfAPathTheAssetNoLongerUsesAreIgnored() async throws {
        let file = try tempFile("one")
        defer { try? FileManager.default.removeItem(at: file) }
        let (project, assetID) = makeProject(file: file)
        let controller = MediaReplacementController()

        controller.apply([assetID: .init(path: "/somewhere/else.mov", stamp: nil)], to: project)

        #expect(controller.missingMedia.isEmpty)
        #expect(controller.notice == nil)
    }
}

private extension EditingProject {
    mutating func setAcceptedStamp(_ stamp: FileStamp?, forAsset id: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].acceptedStamp = stamp
    }
}
