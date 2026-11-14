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
        #expect(run.pieces.allSatisfy { $0.map.points.count == 2 && !$0.isEdited })

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

    @Test func movingAPointToWhereItIsChangesNothing() throws {
        let layout = Layout(starts: [0, 10])
        var run = try layout.run(layout.shots)
        let first = layout.shots[0]
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
        #expect(run.pieces[0].map.trimStart == seconds(3) - run.frameDuration)
        run.trim(first, edge: .end, to: seconds(0))
        #expect(run.pieces[0].map.trimEnd > seconds(3))
    }

    @Test func movingAClipStopsAtItsNeighbourAndNotWithAHit() throws {
        let layout = Layout(starts: [0, 6])
        var run = try layout.run(layout.shots)
        run.movePiece(layout.shots[0], by: seconds(5))
        // Only 2 s of room before the next shot.
        #expect(run.pieces[0].span.start == seconds(2))

        let added3 = run.addMarker(toPiece: layout.shots[0], atSource: seconds(3))
        let hit = try #require(added3)
        run.setLocked(true, ofPoint: hit)
        #expect(!run.canMove(layout.shots[0]))
        run.movePiece(layout.shots[0], by: seconds(-1))
        #expect(run.pieces[0].span.start == seconds(2))
    }

    @Test func doneWritesOnlyWhatChangedOnFrames() throws {
        // Room for the first shot to slow to about 50%.
        var layout = Layout(starts: [0, 12])
        var run = try layout.run(layout.shots)
        let first = layout.shots[0]
        let added4 = run.addMarker(toPiece: first, atSource: seconds(3))
        let hit = try #require(added4)
        run.setLocked(true, ofPoint: hit)
        let added5 = run.addMarker(toPiece: first, atSource: seconds(4))
        let marker = try #require(added5)
        run.movePoint(marker, to: seconds(2.5))
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
        #expect(abs(written.timelineTime(forSourceTime: seconds(3)).seconds - 1) < 1e-4)
        #expect(abs(written.timelineTime(forSourceTime: seconds(4)).seconds - 2.5) < 1e-4)
    }

    @Test func removingTheLastPointKeepsAnUnlockedClipWhereItWasMoved() throws {
        let layout = Layout(starts: [0])
        var run = try layout.run(layout.shots)
        let clip = layout.shots[0]
        let added = run.addMarker(toPiece: clip, atSource: seconds(3))
        let point = try #require(added)
        run.movePoint(point, to: seconds(2))
        let before = run.pieces[0].span
        run.removePoint(point)
        #expect(run.pieces[0].span == before)
        #expect(run.pieces[0].map.points.first?.time == .zero)
    }

    @Test(arguments: [1.5, 2.5]) func interiorRetimingWritesTheSameCutsAndFootage(_ target: Double) throws {
        var layout = Layout(starts: [0])
        let id = layout.shots[0]
        var run = try MotionRun.opening([id], in: layout.timelineID, of: layout.project) { _ in
            CMTimeRange(start: seconds(2), end: seconds(6))
        }.get()
        let added_a = run.addMarker(toPiece: id, atSource: seconds(3))
        let a = try #require(added_a)
        let added_m = run.addMarker(toPiece: id, atSource: seconds(4))
        let m = try #require(added_m)
        let added_b = run.addMarker(toPiece: id, atSource: seconds(5))
        let b = try #require(added_b)
        for point in [a, m, b] { run.setEase(.linear, ofPoint: point) }
        run.setLocked(true, ofPoint: a)
        run.setLocked(true, ofPoint: b)
        run.movePoint(m, to: seconds(target))
        #expect(run.fits)
        #expect(run.pieces[0].map.points[2].time == seconds(target))
        let before = layout.clip(id)
        run.write(into: &layout.project)
        let after = layout.clip(id)
        #expect(after.startOffset == before.startOffset)
        #expect(after.trimStart == before.trimStart && after.trimEnd == before.trimEnd)
        #expect(abs(after.endOffset.seconds - before.endOffset.seconds) < 1e-5)
    }

    @Test func edgeMovesKeepTheirSourceAndStopAtNeighboursAndZero() throws {
        let layout = Layout(starts: [1, 6])
        var run = try layout.run([layout.shots[0]])
        let first = run.pieces[0].map.points[0].id
        let last = try #require(run.pieces[0].map.points.last?.id)
        run.movePoint(first, to: seconds(-1))
        #expect(run.pieces[0].span.start == .zero)
        run.movePoint(last, to: seconds(10))
        #expect(run.pieces[0].span.end == seconds(6))
        #expect(run.pieces[0].map.trimStart == seconds(2))
        #expect(run.pieces[0].map.trimEnd == seconds(6))
        run.movePoint(last, to: seconds(5.51))
        #expect(run.pieces[0].span.end == CMTime(value: 132, timescale: 24))
    }

    @MainActor @Test(arguments: [-0.5, 0.5]) func touchingEdgesMoveTheirCutTogether(_ delta: Double) throws {
        let layout = Layout(starts: [0, 4])
        var run = try layout.run(layout.shots)
        let end = try #require(run.pieces[0].map.points.last?.id)
        let start = run.pieces[1].map.points[0].id
        MotionDesignSession.movePoints([end: 4, start: 4], by: delta, in: &run)
        #expect(run.pieces[0].span.end == seconds(4 + delta))
        #expect(run.pieces[1].span.start == seconds(4 + delta))
        #expect(run.fits)
    }

    @Test func aLockedEdgeBlocksTrimmingAndMovingUntilUnlocked() throws {
        let layout = Layout(starts: [2])
        var run = try layout.run(layout.shots)
        let id = layout.shots[0]
        let edge = run.pieces[0].map.points[0].id
        run.setLocked(true, ofPoint: edge)
        let before = run
        run.trim(id, edge: .start, to: seconds(3))
        run.movePiece(id, by: seconds(1))
        run.movePoint(edge, to: seconds(3))
        #expect(run == before)
        run.setLocked(false, ofPoint: edge)
        run.movePiece(id, by: seconds(1))
        #expect(run.pieces[0].span.start == seconds(3))
    }
}
