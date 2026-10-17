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

    /// The cut piece's end is a frame count minus a few microseconds, which
    /// editing it must read as that count (31 frames), not one less.
    @Test func editingACutPieceKeepsItsFrameCountAndItsNeighbor() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
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
        let cut = CMTime(value: 1001 * 31, timescale: 30000)
        fixture.project.split(placed.clipID, in: tl, layer: placed.layerID, atTimelineTime: cut)
        let first = try #require(fixture.project.timeline(id: tl)?.layer(id: placed.layerID)?.clips.first)
        // Any edit to the piece trims it back to whole frames.
        fixture.project.editTime(ofClip: first.id, in: tl, layer: placed.layerID) { $0.frameBlending = .blend }
        let clips = try #require(fixture.project.timeline(id: tl)?.layer(id: placed.layerID)?.clips)
        // The next piece stays on its frame. The first can't be put
        // exactly on one: where a ramp ends is found to a few microseconds
        // of source time. It must not lose a frame, and building closes
        // the difference.
        #expect(clips[1].startOffset == cut)
        #expect(abs(CMTimeSubtract(clips[0].endOffset, cut).seconds) < Timeline.abutmentTolerance.seconds)
    }

    @Test func theOriginalSequenceMeetsExactlyAndSurvivesSavingAndReopening() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let (layer, frames) = try await cutAndRetime(&fixture)
        let tl = fixture.timelineID
        let frame = CMTime(value: 1001, timescale: 30000)
        let before = try #require(fixture.project.timeline(id: tl)?.layer(id: layer)?.clips)
        // The first piece ends on a frame (the end is exclusive: this is
        // the frame the second piece starts on), and the second begins there.
        #expect(CMTimeMultiply(frame, multiplier: Int32(frames)) == before[0].endOffset)
        #expect(before[0].endOffset == before[1].startOffset)

        // Saved and reopened, the boundary is the same.
        let package = fixture.directory.appending(path: "Saved.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(fixture.project, to: package)
        let media = try #require(fixture.project.clips.first)
        let loaded = try await ProjectStore.load(from: package, importMedia: { _ in media })
        let after = try #require(loaded.project.timeline(id: tl)?.layer(id: layer)?.clips)
        #expect(after.map(\.startOffset) == before.map(\.startOffset))
        #expect(after.map(\.endOffset) == before.map(\.endOffset))

        // And the pictures across it, from the reopened project, aren't black.
        var reopened = fixture
        reopened.project = loaded.project
        let composed = try await reopened.build(forPreview: true)
        for offset in [-1, 0, 1] as [Int64] {
            let gray = try await grayLevel(of: composed, at: CMTimeMultiply(frame, multiplier: Int32(frames + offset)))
            #expect(gray > 100, "frame \(frames + offset) is black")
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
