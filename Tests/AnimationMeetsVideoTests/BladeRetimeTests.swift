import AVFoundation
import CoreMedia
import Testing
@testable import AnimationMeetsVideo

/// Cutting a keyframed clip and then retiming the pieces left a sliver of
/// gap between them, which drew a black frame at the second piece's start.
@MainActor
@Suite struct BladeRetimeTests {
    private func cutAndRetime(_ fixture: inout DrawingFixture) async throws -> (layer: UUID, frames: Int64) {
        let url = fixture.directory.appending(path: "m-\(UUID().uuidString).mov")
        try await writeMovie(to: url, segments: [(120, 96)])
        let media = MediaClip(
            name: "m", kind: .video, url: url, duration: CMTime(value: 96, timescale: 24),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let imported = fixture.project.importClip(media, intoTimeline: fixture.timelineID)
        let placed = try #require(imported)
        let tl = fixture.timelineID
        fixture.project.timelines[0].frameRate = 29.97
        fixture.project.editTime(ofClip: placed.clipID, in: tl, layer: placed.layerID) {
            $0.speed.setAnimated(true, at: CMTime(value: 2, timescale: 1))
            $0.speed.set(185, at: CMTime(value: 2, timescale: 1))
            $0.speed.set(40, at: CMTime(value: 3, timescale: 1))
        }
        // Cut before the first keyframe, on a frame.
        fixture.project.split(placed.clipID, in: tl, layer: placed.layerID, atTimelineTime: CMTime(value: 1001 * 31, timescale: 30000))
        let ids = try #require(fixture.project.timeline(id: tl)?.layer(id: placed.layerID)?.clips.map(\.id))
        for id in ids {
            fixture.project.editTime(ofClip: id, in: tl, layer: placed.layerID) { $0.speed = AnimatedValue(50) }
        }
        let clips = try #require(fixture.project.timeline(id: tl)?.layer(id: placed.layerID)?.clips)
        return (placed.layerID, Int64((clips[0].endOffset.seconds / (1001.0 / 30000)).rounded()))
    }

    @Test func retimingTheCutPiecesKeepsThemMeeting() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let (layer, _) = try await cutAndRetime(&fixture)
        let clips = try #require(fixture.project.timeline(id: fixture.timelineID)?.layer(id: layer)?.clips)
        #expect(clips.count == 2)
        #expect(clips[0].endOffset == clips[1].startOffset)
    }

    @Test func noFrameIsBlackWhereThePiecesMeet() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let (_, frames) = try await cutAndRetime(&fixture)
        let composed = try await fixture.build(forPreview: true)
        for frame in [frames - 1, frames, frames + 1] {
            let gray = try await grayLevel(of: composed, at: CMTime(value: 1001 * frame, timescale: 30000))
            #expect(gray > 100, "frame \(frame) is black")
        }
    }

    @Test func aSliverLeftByAnEarlierCutIsClosedWhenTheTimelineIsBuilt() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let (layer, frames) = try await cutAndRetime(&fixture)
        // Put the sliver back, as in a project cut before this was fixed.
        let tl = fixture.timelineID
        var clips = try #require(fixture.project.timeline(id: tl)?.layer(id: layer)?.clips)
        fixture.project.editClip(clips[1].id, in: tl) { $0.startOffset = CMTimeAdd($0.startOffset, CMTime(value: 1, timescale: 240_000)) }
        clips = try #require(fixture.project.timeline(id: tl)?.layer(id: layer)?.clips)
        #expect(clips[0].endOffset != clips[1].startOffset)
        let composed = try await fixture.build(forPreview: true)
        let gray = try await grayLevel(of: composed, at: CMTime(value: 1001 * frames, timescale: 30000))
        #expect(gray > 100)
    }
}

@Suite struct WholeFrameCoverTests {
    @Test func aLengthJustShortOfAWholeFrameCountIsThatCountNotOneLess() {
        var project = EditingProject.empty
        let media = MediaClip(
            name: "m", kind: .video, url: URL(fileURLWithPath: "/tmp/none.mov"), duration: CMTime(value: 10, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let placed = try! #require(imported)
        let timeline = project.timeline(id: project.rootTimelineID)!
        var clip = project.clipAndLayer(placed.clipID, in: project.rootTimelineID)!.clip
        // 51 frames at 24 fps, less four microseconds.
        clip.trimEnd = CMTimeSubtract(CMTime(value: 51, timescale: 24), CMTime(value: 1, timescale: 240_000))
        let covered = project.coveringWholeFrames(clip, in: timeline)
        #expect(covered.endOffset == CMTime(value: 51, timescale: 24))
        // A real shortfall still rounds down.
        clip.trimEnd = CMTimeSubtract(CMTime(value: 51, timescale: 24), CMTime(value: 1, timescale: 100))
        #expect(project.coveringWholeFrames(clip, in: timeline).endOffset == CMTime(value: 50, timescale: 24))
    }
}
