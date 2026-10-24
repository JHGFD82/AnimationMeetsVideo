import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ProjectChangeTests {
    private static func media() -> MediaClip {
        MediaClip(
            name: "Clip", kind: .video, url: nil,
            duration: CMTime(seconds: 5, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
    }

    /// A project with one clip on one layer of its main timeline.
    private static func oneClip() -> (project: EditingProject, layerID: UUID, clipID: UUID) {
        var project = EditingProject.empty
        let placed = project.importClip(media(), intoTimeline: project.rootTimelineID)!
        return (project, placed.layerID, placed.clipID)
    }

    private func name(_ before: EditingProject, _ change: (inout EditingProject) -> Void) -> String? {
        var after = before
        change(&after)
        return ProjectChange.name(from: before, to: after)
    }

    @Test func nothingChangedHasNoName() {
        let project = EditingProject.empty
        #expect(ProjectChange.name(from: project, to: project) == nil)
    }

    @Test func namesProjectAndMediaChanges() {
        #expect(name(.empty) { $0.name = "Other" } == "Rename Project")
        #expect(name(.empty) { $0.clips.append(Self.media()) } == "Import Media")
    }

    @Test func placingMediaOnATimelineAddsAClip() {
        #expect(name(.empty) { _ = $0.importClip(Self.media(), intoTimeline: $0.rootTimelineID) } == "Add Clip")
    }

    @Test func namesClipEdits() {
        let (project, layerID, clipID) = Self.oneClip()
        let timelineID = project.rootTimelineID
        let second = CMTime(seconds: 1, preferredTimescale: 600)
        #expect(name(project) { $0.split(clipID, in: timelineID, layer: layerID, atTimelineTime: second) } == "Split Clip")
        #expect(name(project) { $0.deleteClip(clipID, in: timelineID, layer: layerID) } == "Delete Clip")
        #expect(name(project) { $0.moveClip(clipID, in: timelineID, layer: layerID, to: second) } == "Move Clip")
        #expect(name(project) { project in
            project.updateLayer(layerID, in: timelineID) { $0.clips[0].trimEnd = second }
        } == "Trim Clip")
        #expect(name(project) { project in
            project.updateLayer(layerID, in: timelineID) { $0.clips[0].enabled = false }
        } == "Turn Clip Off")
    }

    @Test func namesTimelineEdits() {
        let (project, _, _) = Self.oneClip()
        #expect(name(project) {
            _ = $0.addTimeline(name: "B", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        } == "New Timeline")
        #expect(name(project) { $0.timelines[0].name = "Renamed" } == "Rename Timeline")
    }
}
