import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ProjectChangeTests {
    private static func media(_ name: String = "Interview") -> MediaClip {
        MediaClip(
            name: name, kind: .video, url: nil,
            duration: CMTime(seconds: 5, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
    }

    private static let second = CMTime(seconds: 1, preferredTimescale: 600)

    /// A project with one clip on one layer of its main timeline.
    private static func oneClip() -> (project: EditingProject, layerID: UUID, clipID: UUID) {
        var project = EditingProject.empty
        let placed = project.importClip(media(), intoTimeline: project.rootTimelineID)!
        return (project, placed.layerID, placed.clipID)
    }

    private func step(_ before: EditingProject, _ change: (inout EditingProject) -> Void) -> ProjectChange.Step? {
        var after = before
        change(&after)
        return ProjectChange.step(from: before, to: after)
    }

    private func name(_ before: EditingProject, _ change: (inout EditingProject) -> Void) -> String? {
        step(before, change)?.name
    }

    @Test func nothingChangedHasNoStep() {
        let project = EditingProject.empty
        #expect(ProjectChange.step(from: project, to: project) == nil)
    }

    @Test func namesWhatWasDoneToWhichMedia() {
        let project = EditingProject.empty
        #expect(name(project) { $0.name = "Trailer" } == "Rename Project to \u{201C}Trailer\u{201D}")
        #expect(name(project) { $0.clips.append(Self.media()) } == "Import Interview")
        #expect(name(project) { $0.clips += [Self.media(), Self.media("B-roll")] } == "Import 2 Files")
    }

    @Test func placingMediaNamesTheClipAndLayer() {
        let project = EditingProject.empty
        #expect(name(project) { _ = $0.importClip(Self.media(), intoTimeline: $0.rootTimelineID) }
                == "Add Interview to \u{201C}Video 1\u{201D}")
    }

    @Test func namesWhatWasDoneToWhichClip() {
        let (project, layerID, clipID) = Self.oneClip()
        let timelineID = project.rootTimelineID
        let clip = "Interview"
        #expect(name(project) { $0.split(clipID, in: timelineID, layer: layerID, atTimelineTime: Self.second) } == "Split \(clip)")
        #expect(name(project) { $0.deleteClip(clipID, in: timelineID, layer: layerID) } == "Delete \(clip)")
        #expect(name(project) { $0.moveClip(clipID, in: timelineID, layer: layerID, to: Self.second) } == "Move \(clip)")
        #expect(name(project) { project in
            project.updateLayer(layerID, in: timelineID) { $0.clips[0].trimEnd = Self.second }
        } == "Trim End of \(clip)")
        #expect(name(project) { project in
            project.updateLayer(layerID, in: timelineID) { $0.clips[0].enabled = false }
        } == "Turn Off \(clip)")
        #expect(name(project) { project in
            project.updateLayer(layerID, in: timelineID) { $0.clips[0].soundMuted = true }
        } == "Mute \(clip)")
    }

    /// Once a video's scenes are known, a clip is named by the scene it
    /// plays, or the scenes, as numbered in the Clips list.
    @Test func namesTheSceneAClipPlays() {
        let (project, layerID, clipID) = Self.oneClip()
        let timelineID = project.rootTimelineID
        func at(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        let ranges = [
            SceneRange(start: at(0), end: at(1), origin: .auto),
            SceneRange(start: at(1), end: at(3), origin: .auto),
            SceneRange(start: at(3), end: at(5), origin: .auto),
        ]
        let scenes: ProjectChange.SceneLookup = { _, _ in ranges }
        func trimmed(_ start: Double, _ end: Double) -> EditingProject {
            var project = project
            project.updateLayer(layerID, in: timelineID) { layer in
                layer.clips[0].trimStart = at(start)
                layer.clips[0].trimEnd = at(end)
            }
            return project
        }
        let inSecond = trimmed(1, 3)
        var moved = inSecond
        moved.moveClip(clipID, in: timelineID, layer: layerID, to: at(10))
        #expect(ProjectChange.step(from: inSecond, to: moved, scenes: scenes)?.name == "Move Scene 2 of Interview")

        let across = trimmed(0.5, 4)
        var turnedOff = across
        turnedOff.updateLayer(layerID, in: timelineID) { $0.clips[0].enabled = false }
        #expect(ProjectChange.step(from: across, to: turnedOff, scenes: scenes)?.name == "Turn Off Scenes 1–3 of Interview")
    }

    @Test func shortensLongFileNamesKeepingTheExtension() {
        #expect(ProjectChange.shortened(fileName: "video.mp4") == "video.mp4")
        let long = ProjectChange.shortened(fileName: "Interview with the director, take 12 final.mov")
        #expect(long.count == ProjectChange.longestFileName)
        #expect(long.hasSuffix(".mov"))
        #expect(long.contains("…"))
    }

    @Test func namesTheEffectAndControlChanged() throws {
        var (project, layerID, clipID) = Self.oneClip()
        let timelineID = project.rootTimelineID
        let added = step(project) { $0.addEffect(.transform, toClip: clipID, in: timelineID) }
        #expect(added?.name == "Add Transform to Interview")

        project.addEffect(.transform, toClip: clipID, in: timelineID)
        let effect = try #require(project.clipAndLayer(clipID, in: timelineID)?.clip.effects.first)
        let control = try #require(effect.controls.first)
        let changed = name(project) { project in
            project.updateLayer(layerID, in: timelineID) { layer in
                layer.clips[0].effects[0].controls[0].enabled.toggle()
            }
        }
        #expect(changed == "Change Transform \(control.kind.name) on Interview")
    }

    @Test func namesTimelineEdits() {
        let (project, _, _) = Self.oneClip()
        #expect(name(project) {
            _ = $0.addTimeline(name: "B", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        } == "New Timeline \u{201C}B\u{201D}")
        #expect(name(project) { $0.timelines[0].name = "Cut" } == "Rename Timeline to \u{201C}Cut\u{201D}")
    }

    /// Two clips cut from one file read the same, but moving one is not
    /// moving the other, so their steps must not merge.
    @Test func theSameEditToDifferentClipsHasADifferentIdentity() throws {
        var project = EditingProject.empty
        let media = Self.media()
        let placed = project.importClip(media, intoTimeline: project.rootTimelineID)
        let first = try #require(placed)
        let timelineID = project.rootTimelineID
        project.split(first.clipID, in: timelineID, layer: first.layerID, atTimelineTime: Self.second)
        let clips = try #require(project.timeline(id: timelineID)?.layer(id: first.layerID)?.clips)
        let later = CMTime(seconds: 10, preferredTimescale: 600)

        let moveA = step(project) { $0.moveClip(clips[1].id, in: timelineID, layer: first.layerID, to: later) }
        let moveB = step(project) { $0.moveClip(clips[0].id, in: timelineID, layer: first.layerID, to: later) }
        #expect(moveA?.name == moveB?.name)
        #expect(moveA?.identity != moveB?.identity)
    }

    @Test func theSameEditToTheSameClipKeepsItsIdentity() {
        let (project, layerID, clipID) = Self.oneClip()
        let timelineID = project.rootTimelineID
        var moved = project
        moved.moveClip(clipID, in: timelineID, layer: layerID, to: Self.second)
        let first = ProjectChange.step(from: project, to: moved)
        let again = step(moved) { $0.moveClip(clipID, in: timelineID, layer: layerID, to: CMTime(seconds: 2, preferredTimescale: 600)) }
        #expect(first?.identity == again?.identity)
        let trimmed = step(moved) { project in
            project.updateLayer(layerID, in: timelineID) { $0.clips[0].trimEnd = Self.second }
        }
        #expect(trimmed?.identity != first?.identity)
    }
}
