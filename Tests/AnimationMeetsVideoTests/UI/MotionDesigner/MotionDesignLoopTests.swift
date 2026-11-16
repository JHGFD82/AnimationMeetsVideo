import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The loop region in the Motion Designer (docs/loop-region.md, "Motion
/// Designer"): held to the designer's window, made over the run with
/// none, selected for Delete.
@MainActor
@Suite(.serialized) struct MotionDesignLoopTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    /// A designer on four seconds of an adjustment clip at 2 s, its
    /// player showing a sixty-second timeline at 24 fps.
    private func session() throws -> MotionDesignSession {
        var project = EditingProject.empty
        let clip = TimelineClip(source: .adjustment, startOffset: CMTime(value: 2, timescale: 1), trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip])]
        let run = try MotionRun.opening([clip.id], in: project.rootTimelineID, of: project).get()
        let playback = PlaybackModel()
        playback.loop.show(nil, duration: seconds(60), frameDuration: CMTime(value: 1, timescale: 24))
        return MotionDesignSession(run: run, project: project, playback: playback)
    }

    /// Turning the loop on shows the timeline's loop row, written to the
    /// defaults: put back as it was.
    private func keepingAreaLayout(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let remembered = defaults.object(forKey: Preferences.timelineAreaLayout)
        defer { defaults.set(remembered, forKey: Preferences.timelineAreaLayout) }
        try body()
    }

    @Test func theLoopIsHeldToTheWindowWhileOpen() throws {
        let session = try session()
        let loop = session.playback.loop
        #expect(loop.window == session.loopLimits)
        #expect(loop.limits == session.loopLimits)
        // A region past the window loops only what is inside it.
        loop.draw(LoopRegion(start: seconds(1), end: seconds(30)))
        #expect(loop.activeRange?.end == session.loopLimits.end)
        session.end()
        #expect(loop.window == nil)
        #expect(loop.activeRange == CMTimeRange(start: seconds(1), end: seconds(30)))
    }

    @Test func cMakesARegionOverTheClipsAndTurnsItOnAndOff() throws {
        try keepingAreaLayout {
            var hidden = TimelineAreaLayout()
            hidden.showsLoop = false
            UserDefaults.standard.set(hidden.rawValue, forKey: Preferences.timelineAreaLayout)

            let session = try session()
            defer { session.end() }
            let loop = session.playback.loop
            session.toggleLoop()
            #expect(loop.region == LoopRegion(start: seconds(2), end: seconds(6)))
            // On, the timeline's loop row shows, so it isn't turned off there.
            #expect(TimelineAreaLayout.stored.showsLoop)
            session.toggleLoop()
            #expect(loop.region?.isOn == false)
            session.toggleLoop()
            #expect(loop.isOn)
        }
    }

    @Test func selectingTheRegionLetsGoOfMarkersAndTheOtherWayRound() throws {
        let session = try session()
        defer { session.end() }
        session.playback.loop.draw(LoopRegion(start: seconds(2), end: seconds(4)))
        let point = try #require(session.run.pieces.first?.map.points.first?.id)

        session.select(point: point)
        session.selectLoop()
        #expect(session.isLoopSelected)
        #expect(session.pickedPointIDs.isEmpty && session.selectedPieceID == nil)

        session.select(point: point)
        #expect(!session.isLoopSelected)

        session.selectLoop()
        session.deleteLoop()
        #expect(session.playback.loop.region == nil)
        #expect(!session.isLoopSelected)
    }
}
