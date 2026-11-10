import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Each composition keeps the matte wipe maps it was built with, so a later
/// build reading another version of a map's file (the viewer's, after
/// Replace Media while an export runs or waits) doesn't change it.
@Suite struct MatteMapsTests {
    private let probe = RenderProbe()

    /// A dark and a light movie in a new folder, removed by `finish`.
    private func movies() async throws -> (folder: URL, dark: URL, light: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "amv-mattes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dark = folder.appending(path: "dark.mov"), light = folder.appending(path: "light.mov")
        try await writeMovie(to: dark, segments: [(luma: 40, frames: 24)])
        try await writeMovie(to: light, segments: [(luma: 220, frames: 24)])
        return (folder, dark, light)
    }

    private func project(mapping map: URL) throws -> (project: EditingProject, mapID: UUID) {
        var project = EditingProject.empty
        let media = MediaClip(name: "map", kind: .video, url: map, duration: CMTime(value: 24, timescale: 24),
                              frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let placed = project.importClip(media, intoTimeline: project.rootTimelineID)
        let ids = try #require(placed)
        var options = TransitionKind.matteWipe.defaultOptions
        options.matte = .clip(media.id)
        project.editClip(ids.clipID, in: project.rootTimelineID) {
            $0.transitionIn = ClipTransition(kind: .matteWipe, duration: CMTime(value: 1, timescale: 2), options: options)
        }
        return (project, media.id)
    }

    /// `project` with the map's clip pointing at `url`, as Replace Media
    /// leaves it.
    private func replacing(_ mapID: UUID, in project: EditingProject, with url: URL) throws -> EditingProject {
        var project = project
        let index = try #require(project.clips.firstIndex { $0.id == mapID })
        project.clips[index].url = url
        return project
    }

    /// The green level at the centre of the map `mattes` holds for `id`.
    private func centreGreen(_ mattes: MatteMapSet, _ id: UUID) throws -> Int {
        #expect(mattes.images[id] != nil)
        let map = TransitionRenderer.matteMap(.clip(id), in: probe.bounds, mattes: mattes)
        return try probe.pixel(map, x: 0.5, y: 0.5)[1]
    }

    @Test func aNewerVersionOfAMapLeavesTheOneLoadedBeforeAsItWas() async throws {
        let files = try await movies()
        defer { try? FileManager.default.removeItem(at: files.folder) }
        let (old, mapID) = try project(mapping: files.dark)
        let new = try replacing(mapID, in: old, with: files.light)

        let maps = MatteMaps()
        let before = await maps.load(for: old)
        let after = await maps.load(for: new)

        #expect(before.stamps[mapID] != nil)
        #expect(before.stamps[mapID] != after.stamps[mapID])
        #expect(try centreGreen(before, mapID) < 80)
        #expect(try centreGreen(after, mapID) > 180)
    }

    @Test func aCompositionKeepsTheMapsItWasBuiltWith() async throws {
        let files = try await movies()
        defer { try? FileManager.default.removeItem(at: files.folder) }
        let (old, mapID) = try project(mapping: files.dark)
        let new = try replacing(mapID, in: old, with: files.light)

        let exported = try await CompositionExporter.buildComposedTimeline(for: old, timelineID: old.rootTimelineID)
        let viewed = try await CompositionExporter.buildComposedTimeline(
            for: new, timelineID: new.rootTimelineID, forPreview: true
        )

        let first = try #require(exported.videoComposition?.instructions.first as? LayeredInstruction)
        #expect(try centreGreen(first.mattes, mapID) < 80)
        let later = try #require(viewed.videoComposition?.instructions.first as? LayeredInstruction)
        #expect(try centreGreen(later.mattes, mapID) > 180)
    }
}
