import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

/// A timeline at 24 fps with shots on one video layer, each 4 s of a 20 s
/// file, at the starts given.
private struct Layout {
    var project = EditingProject.empty
    var timelineID: UUID { project.rootTimelineID }
    let layerID = UUID()
    var shots: [UUID] = []

    init(starts: [Double], secondLayer: Bool = false) {
        var clips: [TimelineClip] = []
        for start in starts {
            let asset = MediaClip(name: "Shot", kind: .video, url: nil, duration: seconds(20), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
            project.addMedia(asset)
            let clip = TimelineClip(source: .media(asset.id), startOffset: seconds(start), trimStart: seconds(2), trimEnd: seconds(6))
            clips.append(clip)
            shots.append(clip.id)
        }
        project.timelines[0].layers.append(TimelineLayer(id: layerID, customName: nil, kind: .video, clips: clips))
    }

    func run(_ ids: [UUID]) throws -> MotionRun {
        try MotionRun.opening(Set(ids), in: timelineID, of: project).get()
    }

    func clip(_ id: UUID) -> TimelineClip {
        project.clipAndLayer(id, in: timelineID)!.clip
    }
}

@Suite struct MotionRunTests {
    @Test func opensOnClipsOfOneLayerOnly() throws {
        var layout = Layout(starts: [0, 4])
        let run = try layout.run(layout.shots)
        #expect(run.pieces.map(\.id) == layout.shots)
        #expect(run.others.isEmpty)
        #expect(run.pieces.allSatisfy { $0.map.points.isEmpty && !$0.isEdited })

        let other = TimelineClip(source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: seconds(1))
        layout.project.timelines[0].layers.append(TimelineLayer(customName: nil, kind: .video, clips: [other]))
        #expect(MotionRun.opening([layout.shots[0], other.id], in: layout.timelineID, of: layout.project) == .failure(.severalLayers))
        #expect(MotionRun.opening([], in: layout.timelineID, of: layout.project) == .failure(.nothingSelected))
    }

    @Test func refusesClipsThatPlayBackwards() {
        var layout = Layout(starts: [0])
        layout.project.editClip(layout.shots[0], in: layout.timelineID) { $0.time.setReversed(true) }
        #expect(MotionRun.opening(Set(layout.shots), in: layout.timelineID, of: layout.project) == .failure(.reversed))
    }

    @Test func clipsLeftOutBoundTheRun() throws {
        let layout = Layout(starts: [0, 4, 10])
        let run = try layout.run([layout.shots[0], layout.shots[2]])
        #expect(run.others == [CMTimeRange(start: seconds(4), end: seconds(8))])
    }

    @Test func slowingAClipKeepsItsFootageUntilItMeetsItsNeighbour() throws {
        // The first shot ends at 4 s, where the second starts.
        let layout = Layout(starts: [0, 4])
        var run = try layout.run(layout.shots)
        let first = layout.shots[0]
        let added1 = run.addMarker(toPiece: first, atSource: seconds(2))
        run.setKind(.hit, ofPoint: try #require(added1))
        let added2 = run.addMarker(toPiece: first, atSource: seconds(3))
        let marker = try #require(added2)
        // 1 s of footage over 4 s: 25%, which would run far past 4 s, so
        // the footage stops against the second shot.
        run.movePoint(marker, to: seconds(4))
        #expect(run.fits)
        #expect(abs(run.pieces[0].span.end.seconds - 4) < 1e-6)
        #expect(abs(run.pieces[0].map.trimEnd.seconds - 3) < 1e-6)
        #expect(run.pieces[0].isEdited && !run.pieces[1].isEdited)
        // Sped up again, the footage cut comes back: 1 s over 0.5 s is
        // 200%, so all 4 s of it end at 2 s.
        run.movePoint(marker, to: seconds(0.5))
        #expect(abs(run.pieces[0].map.trimEnd.seconds - 6) < 1e-6)
        #expect(abs(run.pieces[0].span.end.seconds - 2) < 1e-6)
    }

    @Test func slowingAClipWithRoomLengthensItInsteadOfCuttingIt() throws {
        let layout = Layout(starts: [0, 12])
        var run = try layout.run(layout.shots)
        let first = layout.shots[0]
        let added1 = run.addMarker(toPiece: first, atSource: seconds(2))
        run.setKind(.hit, ofPoint: try #require(added1))
        let added2 = run.addMarker(toPiece: first, atSource: seconds(4))
        // 50%: the 4 s of footage now take 8 s.
        run.movePoint(try #require(added2), to: seconds(4))
        #expect(run.pieces[0].map.trimStart == seconds(2) && run.pieces[0].map.trimEnd == seconds(6))
        #expect(abs(run.pieces[0].span.end.seconds - 8) < 1e-6)
    }

    @Test func speedingUpKeepsItsFootageAndShortensTheClip() throws {
        let layout = Layout(starts: [0, 10])
        var run = try layout.run(layout.shots)
        let first = layout.shots[0]
        let added1 = run.addMarker(toPiece: first, atSource: seconds(2))
        run.setKind(.hit, ofPoint: try #require(added1))
        let added2 = run.addMarker(toPiece: first, atSource: seconds(3))
        // 200%: the 3 s after the marker play in 1.5 s.
        run.movePoint(try #require(added2), to: seconds(0.5))
        #expect(run.pieces[0].map.trimEnd == seconds(6))
        #expect(abs(run.pieces[0].span.end.seconds - 2) < 1e-6)
    }

    @Test func movingAPointToWhereItIsChangesNothing() throws {
        let layout = Layout(starts: [0, 10])
        var run = try layout.run(layout.shots)
        let first = layout.shots[0]
        let added1 = run.addMarker(toPiece: first, atSource: seconds(2))
        let pace = try #require(added1)
        run.setKind(.pace(50), ofPoint: pace)
        let added2 = run.addMarker(toPiece: first, atSource: seconds(3))
        let after = try #require(added2)
        let before = run
        // The point after a pace marker sets that pace when moved; staying
        // put mustn't reset it.
        let point = try #require(run.pieces[0].map.points.first { $0.id == after })
        run.movePoint(after, to: point.time)
        #expect(run == before)
    }

    @Test func trimmingAnEdgeRevealsFootageUpToItsSceneAndNeighbours() throws {
        let layout = Layout(starts: [4, 12])
        var run = try MotionRun.opening(Set(layout.shots), in: layout.timelineID, of: layout.project) { _ in
            CMTimeRange(start: .zero, end: seconds(16))
        }.get()
        let first = layout.shots[0]
        // The end out to 10 s reveals 2 s more footage.
        run.trim(first, edge: .end, to: seconds(10))
        #expect(abs(run.pieces[0].map.trimEnd.seconds - 8) < 1e-6)
        // Further, it stops against the next shot at 12 s.
        run.trim(first, edge: .end, to: seconds(20))
        #expect(abs(run.pieces[0].span.end.seconds - 12) < 1e-3)
        // The start back to 2 s reveals the file's first 2 s; there is none
        // before that.
        run.trim(first, edge: .start, to: seconds(2))
        #expect(run.pieces[0].map.trimStart == .zero)
        #expect(abs(run.pieces[0].span.start.seconds - 2) < 1e-6)
        run.trim(first, edge: .start, to: seconds(1))
        #expect(abs(run.pieces[0].span.start.seconds - 2) < 1e-6)
        #expect(run.pieces[0].isAtFootageEdge(.start))
        // And in, it hides footage, keeping at least a frame.
        run.trim(first, edge: .end, to: seconds(1))
        #expect(run.pieces[0].map.trimEnd > run.pieces[0].map.trimStart)
    }

    @Test func aClipsFootageIsItsSceneOrTheScenesItSpans() throws {
        var layout = Layout(starts: [0])
        let clip = layout.clip(layout.shots[0])
        guard case .media(let assetID) = clip.source else { return }
        let index = try #require(layout.project.clips.firstIndex { $0.id == assetID })
        // Cuts at 1 s and 8 s make the shot's trim, 2 s to 6 s, one scene.
        layout.project.clips[index].sceneEdits.manualCuts = [seconds(1), seconds(8)]
        #expect(layout.project.sceneFootage(of: clip, track: nil) == CMTimeRange(start: seconds(1), end: seconds(8)))
        // Merged (no cut at 8 s), the scene runs to the file's end.
        layout.project.clips[index].sceneEdits.manualCuts = [seconds(1)]
        #expect(layout.project.sceneFootage(of: clip, track: nil) == CMTimeRange(start: seconds(1), end: seconds(20)))
        // A clip across a cut reaches both scenes.
        layout.project.clips[index].sceneEdits.manualCuts = [seconds(1), seconds(4), seconds(8)]
        #expect(layout.project.sceneFootage(of: clip, track: nil) == CMTimeRange(start: seconds(1), end: seconds(8)))
    }

    @Test func aTrimStopsAtTheOutermostPoint() throws {
        let layout = Layout(starts: [0])
        var run = try layout.run(layout.shots)
        let first = layout.shots[0]
        run.addMarker(toPiece: first, atSource: seconds(3))
        run.trim(first, edge: .start, to: seconds(3))
        #expect(run.pieces[0].map.trimStart == seconds(3))
        run.trim(first, edge: .end, to: seconds(0))
        #expect(run.pieces[0].map.trimEnd == seconds(3))
    }

    @Test func movingAClipStopsAtItsNeighbourAndNotWithAHit() throws {
        let layout = Layout(starts: [0, 6])
        var run = try layout.run(layout.shots)
        run.movePiece(layout.shots[0], by: seconds(5))
        // Only 2 s of room before the next shot.
        #expect(run.pieces[0].span.start == seconds(2))

        let added3 = run.addMarker(toPiece: layout.shots[0], atSource: seconds(3))
        let hit = try #require(added3)
        run.setKind(.hit, ofPoint: hit)
        #expect(!run.canMove(layout.shots[0]))
        run.movePiece(layout.shots[0], by: seconds(-1))
        #expect(run.pieces[0].span.start == seconds(2))
    }

    @Test func doneWritesOnlyWhatChangedOnFrames() throws {
        // Room for the first shot to slow to about 50%.
        var layout = Layout(starts: [0, 12])
        var run = try layout.run(layout.shots)
        let first = layout.shots[0]
        let added4 = run.addMarker(toPiece: first, atSource: seconds(2))
        let hit = try #require(added4)
        run.setKind(.hit, ofPoint: hit)
        let added5 = run.addMarker(toPiece: first, atSource: seconds(4))
        let marker = try #require(added5)
        run.movePoint(marker, to: seconds(4.01))
        let untouched = layout.clip(layout.shots[1])
        run.trim(layout.shots[0], edge: .end, to: seconds(7))
        run.write(into: &layout.project)

        let written = layout.clip(first)
        // The trimmed end, on a frame.
        #expect(abs(written.endOffset.seconds - 7) < 0.05)
        #expect(layout.clip(layout.shots[1]) == untouched)
        // On a frame, with the hit's frame still at the hit's time.
        let timeline = try #require(layout.project.timeline(id: layout.timelineID))
        #expect(timeline.frameAligned(written.startOffset, .nearest) == written.startOffset)
        #expect(abs(written.timelineTime(forSourceTime: seconds(2)).seconds) < 1e-4)
        #expect(abs(written.timelineTime(forSourceTime: seconds(4)).seconds - 4.01) < 1e-4)
    }
}
