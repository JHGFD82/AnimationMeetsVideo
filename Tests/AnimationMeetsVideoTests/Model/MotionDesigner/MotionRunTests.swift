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

    @Test func aClipGrowingIntoItsNeighbourStopsThere() throws {
        // The first shot ends at 4 s, where the second starts.
        let layout = Layout(starts: [0, 4])
        var run = try layout.run(layout.shots)
        let first = layout.shots[0]
        let added1 = run.addMarker(toPiece: first, atSource: seconds(2))
        let hit = try #require(added1)
        run.setKind(.hit, ofPoint: hit)
        let added2 = run.addMarker(toPiece: first, atSource: seconds(3))
        let marker = try #require(added2)
        // Slowing the shot down would make it run past 4 s.
        run.movePoint(marker, to: seconds(4))
        #expect(run.fits)
        #expect(abs(run.pieces[0].span.end.seconds - 4) < 0.01)
        #expect(run.pieces[0].isEdited && !run.pieces[1].isEdited)
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
        run.write(into: &layout.project)

        let written = layout.clip(first)
        #expect(layout.clip(layout.shots[1]) == untouched)
        // On a frame, with the hit's frame still at the hit's time.
        let timeline = try #require(layout.project.timeline(id: layout.timelineID))
        #expect(timeline.frameAligned(written.startOffset, .nearest) == written.startOffset)
        #expect(abs(written.timelineTime(forSourceTime: seconds(2)).seconds) < 1e-4)
        #expect(abs(written.timelineTime(forSourceTime: seconds(4)).seconds - 4.01) < 1e-4)
    }
}
