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

    @Test func thePlayerPlaysTheDraftAndFollowsEdits() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-motion-session-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeMovie(to: url, segments: [(60, 96), (200, 96)])
        let footage = MediaClip(
            name: "Shot", kind: .video, url: url, duration: CMTime(value: 8, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        var project = EditingProject.empty
        project.addMedia(footage)
        let clip = TimelineClip(source: .media(footage.id), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip])]
        let run = try MotionRun.opening([clip.id], in: project.rootTimelineID, of: project).get()
        let session = MotionDesignSession(run: run, project: project)
        defer { session.end() }

        // The first build replaces the music-only start with the draft.
        try await wait { session.showsDraft && !session.isUpdatingPreview }
        #expect(session.showsDraft)
        #expect(session.previewError == nil)
        let first = try #require(session.player.currentItem)
        #expect(abs(first.asset.duration.seconds - 4) < 0.05)

        // Paused frames are drawn from the draft: 1 s in is the dark
        // footage, 5 s in (once trimmed out) the bright.
        let dark = try #require(await session.draftFrame(at: 1))
        #expect(Self.brightness(of: dark) < 0.4)
        #expect(session.lastDraftFrame != nil)

        // An edit rebuilds it: the end trimmed out to 6 s.
        session.perform("Trim Clip") { $0.trim(clip.id, edge: .end, to: CMTime(value: 6, timescale: 1)) }
        #expect(session.isUpdatingPreview)
        try await wait { session.player.currentItem !== first && !session.isUpdatingPreview }
        let rebuilt = try #require(session.player.currentItem)
        #expect(rebuilt !== first)
        #expect(abs(rebuilt.asset.duration.seconds - 6) < 0.05)
        #expect(rebuilt.videoComposition != nil)

        let bright = try #require(await session.draftFrame(at: 5))
        #expect(Self.brightness(of: bright) > 0.6)

        // What it plays is what Done would write.
        let draft = session.draftProject
        #expect(abs((draft.timeline(id: draft.rootTimelineID)?.duration.seconds ?? 0) - 6) < 0.05)
    }

    @Test func zoomingOrScrollingPastAnEdgeStretchesInstead() throws {
        var project = EditingProject.empty
        let clip = TimelineClip(source: .adjustment, startOffset: CMTime(value: 2, timescale: 1), trimStart: .zero, trimEnd: CMTime(value: 10, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip])]
        let run = try MotionRun.opening([clip.id], in: project.rootTimelineID, of: project).get()
        let session = MotionDesignSession(run: run, project: project)
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
        let session = MotionDesignSession(run: run, project: project)
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
}
