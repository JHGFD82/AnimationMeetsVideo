import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct AlignmentOffsetCompositionTests {
    private func project(movie: URL, offset: CMTime) -> EditingProject {
        var project = EditingProject.empty
        var media = MediaClip(
            name: "m", kind: .video, url: movie,
            duration: CMTime(seconds: 2, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        media.alignmentOffset = offset
        let ids = project.importClip(media, intoTimeline: project.rootTimelineID)!
        let t = project.timelines.firstIndex { $0.id == project.rootTimelineID }!
        let l = project.timelines[t].layers.firstIndex { $0.id == ids.layerID }!
        project.timelines[t].layers[l].clips[0].trimStart = CMTime(seconds: 0.5, preferredTimescale: 600)
        project.timelines[t].layers[l].clips[0].trimEnd = CMTime(seconds: 1.5, preferredTimescale: 600)
        return project
    }

    private func sourceStart(of composed: ComposedTimeline) throws -> Double {
        let track = try #require(composed.composition.tracks(withMediaType: .video).first)
        let segment = try #require(track.segments.first { !$0.isEmpty })
        return segment.timeMapping.source.start.seconds
    }

    @Test func theClipReadsTheFileAtTheOffsetTime() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "amv-offset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appending(path: "m.mov")
        try await writeMovie(to: movie, segments: [(luma: 40, frames: 24), (luma: 220, frames: 24)])

        let plain = project(movie: movie, offset: .zero)
        let shifted = project(movie: movie, offset: CMTime(seconds: 0.25, preferredTimescale: 600))

        let before = try await CompositionExporter.buildComposedTimeline(for: plain, timelineID: plain.rootTimelineID)
        let after = try await CompositionExporter.buildComposedTimeline(for: shifted, timelineID: shifted.rootTimelineID)

        #expect(abs(try sourceStart(of: before) - 0.5) < 0.05)
        #expect(abs(try sourceStart(of: after) - 0.75) < 0.05)
    }
}
