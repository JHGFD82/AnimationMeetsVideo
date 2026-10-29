import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
@Suite(.serialized) struct MotionDesignSessionTests {
    /// Waits for `condition`, up to `seconds`.
    private func wait(_ seconds: Double = 15, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// The mean of a picture's middle pixel's channels, 0 to 1.
    private static func brightness(of image: CGImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
    }

    @Test func editsReachTheProjectAsTheyAreMade() throws {
        var project = EditingProject.empty
        let clip = TimelineClip(source: .adjustment, startOffset: CMTime(value: 2, timescale: 1), trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip])]
        let run = try MotionRun.opening([clip.id], in: project.rootTimelineID, of: project).get()
        let session = MotionDesignSession(run: run, project: project, playback: PlaybackModel())
        defer { session.end() }
        var applied: [EditingProject] = []
        session.onDraftChange = { applied.append($0) }
        func placed() -> TimelineClip? { applied.last?.clipAndLayer(clip.id, in: project.rootTimelineID)?.clip }

        // A move, every step of a drag included.
        session.beginDrag()
        session.dragPiece(clip.id, by: CMTime(value: 1, timescale: 2))
        #expect(placed()?.startOffset == CMTime(value: 5, timescale: 2))
        session.dragPiece(clip.id, by: CMTime(value: 1, timescale: 1))
        #expect(placed()?.startOffset == CMTime(value: 3, timescale: 1))
        session.endDrag("Move Clip")

        // A marker moved after a hit retimes the clip: 1 s of footage over
        // 2 s, so 50% (with a third point, speed keyframes).
        let pinned = session.addMarker(toPiece: clip.id, atTime: 4)
        session.setKind(.hit, ofPoint: try #require(pinned))
        let added = session.addMarker(toPiece: clip.id, atTime: 5)
        let marker = try #require(added)
        session.perform("Move Point") { $0.movePoint(marker, to: CMTime(value: 6, timescale: 1)) }
        let speed = placed()?.time.speed.value(at: .zero)
        #expect(speed.map { abs($0 - 50) < 1e-6 } == true)

        // Undoing in the panel puts the project back too.
        while session.undoManager.canUndo { session.undoManager.undo() }
        #expect(placed() == clip)
    }

    @Test func aDragDraggedBackToWhereItBeganChangesNothing() throws {
        // A shot with a neighbour 1 s after it.
        var project = EditingProject.empty
        func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }
        let clip = TimelineClip(source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: seconds(4))
        let next = TimelineClip(source: .adjustment, startOffset: seconds(5), trimStart: .zero, trimEnd: seconds(2))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip, next])]
        let run = try MotionRun.opening([clip.id], in: project.rootTimelineID, of: project).get()
        let session = MotionDesignSession(run: run, project: project, playback: PlaybackModel())
        defer { session.end() }
        let pinned = session.addMarker(toPiece: clip.id, atTime: 1)
        session.setKind(.hit, ofPoint: try #require(pinned))
        let added = session.addMarker(toPiece: clip.id, atTime: 2)
        let marker = try #require(added)
        let before = session.run

        // Slowed to 25%, the shot runs into its neighbour and is cut there;
        // dragged back, it has all its footage again, and nothing changed.
        session.beginDrag()
        session.dragEdit { $0.movePoint(marker, to: seconds(5)) }
        #expect(session.run.pieces[0].map.trimEnd < seconds(4))
        session.dragEdit { $0.movePoint(marker, to: seconds(2)) }
        session.endDrag("Move Point")
        #expect(session.run == before)
    }

    @Test func zoomingOrScrollingPastAnEdgeStretchesInstead() throws {
        var project = EditingProject.empty
        let clip = TimelineClip(source: .adjustment, startOffset: CMTime(value: 2, timescale: 1), trimStart: .zero, trimEnd: CMTime(value: 10, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip])]
        let run = try MotionRun.opening([clip.id], in: project.rootTimelineID, of: project).get()
        let session = MotionDesignSession(run: run, project: project, playback: PlaybackModel())
        defer { session.end() }
        session.viewWidth = 800

        // Out past the whole window (the clip's 10 s and a second either
        // side, across 800 points).
        session.zoom(by: 0.01, aboutX: 400)
        #expect(abs(session.secondsPerPoint - session.farthestZoom) < 1e-12)
        #expect(abs(session.farthestZoom - 12.0 / 800) < 1e-9)
        #expect(session.zoomBand.scale < 1)
        // In past a frame 80 points wide.
        session.zoomBand.release()
        session.zoom(by: 10_000, aboutX: 400, pinching: true)
        #expect(abs(session.secondsPerPoint - session.closestZoom) < 1e-12)
        #expect(session.zoomBand.scale > 1)
        session.endPinch()
        #expect(session.zoomBand.settle == .lifted)

        // Before the window's start, the lanes slide on instead.
        session.zoomBand.release()
        session.fit()
        session.scroll(byPoints: -10_000)
        #expect(session.visibleStart == 1)
        #expect(session.scrollBand.offset(length: 800) > 0)
    }

    @Test func theWindowIsTheRunAndFollowsItsMoves() throws {
        // A long song under a 4 s clip at 20 s.
        var project = EditingProject.empty
        let song = MediaClip(name: "Song", kind: .audio, url: nil, duration: CMTime(value: 180, timescale: 1), frameRate: 0, colorSpace: .rec709, codecName: "AAC")
        project.addMedia(song)
        let music = TimelineClip(source: .media(song.id), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 180, timescale: 1))
        let clip = TimelineClip(source: .adjustment, startOffset: CMTime(value: 20, timescale: 1), trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        project.timelines[0].layers = [
            TimelineLayer(customName: nil, kind: .video, clips: [clip]),
            TimelineLayer(customName: nil, kind: .music, clips: [music]),
        ]
        let run = try MotionRun.opening([clip.id], in: project.rootTimelineID, of: project).get()
        let session = MotionDesignSession(run: run, project: project, playback: PlaybackModel())
        defer { session.end() }
        session.viewWidth = 800

        // The clip with half a second either side, not the whole song.
        #expect(session.window.start == 19.5)
        #expect(session.window.end == 24.5)
        session.zoom(by: 0.01, aboutX: 400)
        let shown = Double(session.viewWidth) * session.secondsPerPoint
        #expect(abs(shown - 5) < 1e-9)
        session.seek(to: 100)
        #expect(session.playhead == 24.5)

        // Moving the clip later takes the window along.
        session.perform("Move Clip") { $0.movePiece(clip.id, by: CMTime(value: 2, timescale: 1)) }
        #expect(session.window.start == 19.5)
        #expect(abs(session.window.end - 26.5) < 1e-6)
    }

    @Test func aMovedClipSnapsByEitherEdge() throws {
        // A clip at 2 s to 6 s, and another left out at 8 s.
        var project = EditingProject.empty
        let clip = TimelineClip(source: .adjustment, startOffset: CMTime(value: 2, timescale: 1), trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        let other = TimelineClip(source: .adjustment, startOffset: CMTime(value: 8, timescale: 1), trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip, other])]
        let run = try MotionRun.opening([clip.id], in: project.rootTimelineID, of: project).get()
        let session = MotionDesignSession(run: run, project: project, playback: PlaybackModel())
        defer { session.end() }

        // Its end comes within a tenth of a second of the other's start.
        session.beginDrag()
        session.dragPiece(clip.id, by: CMTime(seconds: 1.95, preferredTimescale: 600), snapTolerance: 0.1)
        #expect(session.run.pieces[0].span.start == CMTime(value: 4, timescale: 1))
        #expect(session.dragSnapTime == 8)
        // Its start near where it began, the playhead.
        session.dragPiece(clip.id, by: CMTime(seconds: 0.07, preferredTimescale: 600), snapTolerance: 0.1)
        #expect(session.run.pieces[0].span.start == CMTime(value: 2, timescale: 1))
        // Off, it lands where it was dragged, on a frame.
        session.snaps = false
        session.dragPiece(clip.id, by: CMTime(seconds: 1.95, preferredTimescale: 600), snapTolerance: 0.1)
        #expect(abs(session.run.pieces[0].span.start.seconds - (2 + 47.0 / 24)) < 1e-9)
        session.endDrag("Move Clip")
        #expect(session.dragSnapTime == nil)
    }

    @Test func easingSaysWhenThereIsNothingToEase() throws {
        var project = EditingProject.empty
        let clip = TimelineClip(source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 8, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip])]
        let run = try MotionRun.opening([clip.id], in: project.rootTimelineID, of: project).get()
        let session = MotionDesignSession(run: run, project: project, playback: PlaybackModel())
        defer { session.end() }
        let hit = try #require(session.addMarker(toPiece: clip.id, atTime: 1))
        session.setKind(.hit, ofPoint: hit)
        let marker = try #require(session.addMarker(toPiece: clip.id, atTime: 3))
        session.perform("Move Point") { $0.movePoint(marker, to: CMTime(value: 4, timescale: 1)) }

        // A hit on a straight line eases, as a keyframe does: it slows into
        // the beat and out of it.
        session.select(point: hit)
        session.setEase(.easyEase, ofPoint: hit)
        #expect(session.selectedPoint?.easePreset == .easyEase)
        #expect(session.undoManager.undoActionName == "Easy Ease")

        // A lone pace marker on the clip's first frame has no footage before
        // it, and holds the stretch after it, so easing it says so and takes
        // no undo step.
        session.select(point: marker)
        session.deleteSelected()
        session.select(point: hit)
        session.deleteSelected()
        let first = try #require(session.addMarker(toPiece: clip.id, atTime: 0))
        session.setKind(.pace(100), ofPoint: first)
        let undoName = session.undoManager.undoActionName
        session.setEase(.easyEase, ofPoint: first)
        #expect(session.selectedPoint?.easePreset == .linear)
        #expect(session.message == MotionDesignSession.nothingToEase)
        #expect(session.undoManager.undoActionName == undoName)
    }

    @Test func undoAndRedoStepThroughTheDraft() throws {
        var project = EditingProject.empty
        let clip = TimelineClip(source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip])]
        let run = try MotionRun.opening([clip.id], in: project.rootTimelineID, of: project).get()
        let session = MotionDesignSession(run: run, project: project, playback: PlaybackModel())
        defer { session.end() }
        #expect(!session.canUndo && !session.canRedo)

        let opened = session.run
        session.addMarker(toPiece: clip.id, atTime: 1)
        let marked = session.run
        #expect(session.canUndo && !session.canRedo)
        #expect(session.undoTitle == "Undo Add Marker")

        session.undo()
        #expect(session.run == opened)
        #expect(!session.canUndo && session.canRedo)
        #expect(session.redoTitle == "Redo Add Marker")

        session.redo()
        #expect(session.run == marked)
        #expect(session.canUndo && !session.canRedo)

        // Not during a drag, whose start the undo would land under.
        session.beginDrag()
        #expect(!session.canUndo)
        session.undo()
        #expect(session.run == marked)
        session.endDrag("Move Point")
        #expect(session.canUndo)
    }
}
