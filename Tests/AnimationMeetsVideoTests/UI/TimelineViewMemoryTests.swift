import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Where each timeline was left in a window, and saving it with the project.
@MainActor
struct TimelineViewMemoryTests {
    /// The Main timeline, four seconds of an adjustment clip, and its IDs.
    private func project() -> (EditingProject, layerID: UUID, clipID: UUID) {
        var project = EditingProject.empty
        let clip = TimelineClip(source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        let layer = TimelineLayer(customName: nil, kind: .video, clips: [clip])
        project.timelines[0].layers = [layer]
        return (project, layer.id, clip.id)
    }

    private func package() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-memory-\(UUID().uuidString).amv", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aPlayheadIsHeldBackToATimelineShortenedSince() {
        let (project, _, _) = project()
        let main = project.rootTimelineID
        let memory = TimelineViewMemory()
        #expect(memory.time(in: main, of: project) == .zero)
        memory.update(main) { $0.time = CMTime(value: 2, timescale: 1) }
        #expect(memory.time(in: main, of: project) == CMTime(value: 2, timescale: 1))
        memory.update(main) { $0.time = CMTime(value: 9, timescale: 1) }
        #expect(memory.time(in: main, of: project) == CMTime(value: 4, timescale: 1))
    }

    @Test func aSelectionComesBackOnlyWhileItsClipIsThere() {
        var (project, layerID, clipID) = project()
        let main = project.rootTimelineID
        let memory = TimelineViewMemory()
        let selection = TimelineSelection(timelineID: main, layerID: layerID, timelineClipID: clipID, transitionEdge: .leading)
        memory.update(main) { $0.selection = selection }
        // Its transition is gone: the clip is selected.
        #expect(memory.selection(in: main, of: project) == TimelineSelection(timelineID: main, layerID: layerID, timelineClipID: clipID))
        project.editClip(clipID, in: main) { $0.transitionIn = ClipTransition(kind: .crossDissolve, duration: CMTime(value: 1, timescale: 2)) }
        #expect(memory.selection(in: main, of: project) == selection)
        project.timelines[0].layers = []
        #expect(memory.selection(in: main, of: project) == nil)
    }

    @Test func theOpenTimelineMustStillBeInTheProject() {
        let (project, _, _) = project()
        let memory = TimelineViewMemory()
        memory.noteOpen(UUID())
        #expect(memory.openTimeline(in: project) == nil)
        memory.noteOpen(project.rootTimelineID)
        #expect(memory.openTimeline(in: project) == project.rootTimelineID)
    }

    @Test func savingReadsTheOpenTimelineFirstAndWritesOnlyChanges() throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        let (project, _, _) = project()
        let main = project.rootTimelineID
        let memory = TimelineViewMemory()
        // Nothing to save into before a package.
        memory.save(for: project)
        #expect(!FileManager.default.fileExists(atPath: ViewStateFile.url(in: url).path))

        memory.load(from: url)
        var scrolled: Double = 120
        memory.register("timeline") { memory.update(main) { $0.scrollX = scrolled } }
        memory.save(for: project)
        #expect(ViewStateFile.read(from: url).timelines[main]?.scrollX == 120)

        // Unchanged: not written again.
        try FileManager.default.removeItem(at: ViewStateFile.url(in: url))
        memory.save(for: project)
        #expect(!FileManager.default.fileExists(atPath: ViewStateFile.url(in: url).path))

        scrolled = 300
        memory.save(for: project)
        #expect(ViewStateFile.read(from: url).timelines[main]?.scrollX == 300)

        // Read back as the project opens again.
        let reopened = TimelineViewMemory()
        reopened.load(from: url)
        #expect(reopened.parked(main)?.scrollX == 300)
    }

    @Test func savingSomewhereNewWritesEverythingThere() throws {
        let first = try package(), second = try package()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let (project, _, _) = project()
        let main = project.rootTimelineID
        let memory = TimelineViewMemory()
        memory.load(from: first)
        memory.update(main) { $0.scrollX = 50 }
        memory.save(for: project)
        memory.move(to: second)
        memory.save(for: project)
        #expect(ViewStateFile.read(from: second).timelines[main]?.scrollX == 50)
    }

    /// Timelines deleted since, or the empty project a window shows before
    /// its own opens, aren't kept in the file.
    @Test func timelinesTheProjectNoLongerHasArentSaved() throws {
        let url = try package()
        defer { try? FileManager.default.removeItem(at: url) }
        let (project, _, _) = project()
        let gone = UUID()
        let memory = TimelineViewMemory()
        memory.load(from: url)
        memory.update(gone) { $0.scrollX = 10 }
        memory.update(project.rootTimelineID) { $0.scrollX = 20 }
        memory.noteOpen(gone)
        memory.save(for: project)
        let saved = ViewStateFile.read(from: url)
        #expect(saved.timelines.keys.sorted { $0.uuidString < $1.uuidString } == [project.rootTimelineID])
        #expect(saved.openTimelineID == nil)
    }

    @Test func aViewportShowsATimelineAsItWasLeft() {
        let model = TimelineViewportModel()
        model.show(ViewState.Timeline(zoomedPixelsPerSecond: 300, scrollX: 450))
        #expect(model.zoomedPixelsPerSecond == 300 && model.scrollX == 450)
        // The first time, fitted.
        model.show(nil)
        #expect(model.zoomedPixelsPerSecond == nil && model.scrollX == 0)
        // Nonsense from a hand-edited file is ignored.
        model.show(ViewState.Timeline(zoomedPixelsPerSecond: -5, scrollX: .infinity))
        #expect(model.zoomedPixelsPerSecond == nil && model.scrollX == 0)
    }
}
