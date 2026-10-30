import AVFoundation
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// The motion designer's time graph clicked with real events (see
/// `EventHarness`; run with `UI_EVENTS=1`).
@MainActor
@Suite(.serialized, .enabled(if: EventHarness.isEnabled))
struct MotionDesignLanesInteractionTests {
    /// A four-second clip at 2 s, at 100%, in lanes 800 by 400 points.
    private static let size = CGSize(width: 800, height: 400)

    private func session() throws -> MotionDesignSession {
        var project = EditingProject.empty
        let clip = TimelineClip(source: .adjustment, startOffset: CMTime(value: 2, timescale: 1), trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip])]
        let run = try MotionRun.opening([clip.id], in: project.rootTimelineID, of: project).get()
        return MotionDesignSession(run: run, project: project, playback: PlaybackModel())
    }

    /// Where the line is at `seconds`: the graph sits under the ruler and
    /// the footage, above one music lane, with its inset either side; the
    /// clip's four seconds of footage run up the whole of it.
    private func onLine(_ session: MotionDesignSession, at seconds: Double) -> CGPoint {
        let top = MotionDesignLanes.rulerHeight + MotionDesignLanes.filmHeight + 14
        let bottom = Self.size.height - MotionDesignLanes.musicHeight - 14
        return CGPoint(x: session.x(of: seconds), y: bottom - CGFloat((seconds - 2) / 4) * (bottom - top))
    }

    private func points(_ session: MotionDesignSession) -> Int { session.run.pieces.reduce(0) { $0 + $1.map.points.count } }

    @Test func aClickOffTheLineMovesThePlayheadAndAddsNothing() async throws {
        let session = try session()
        defer { session.end() }
        let marker = try #require(session.addMarker(toPiece: session.run.pieces[0].id, atTime: 5))
        #expect(session.selectedPoint?.id == marker)
        let harness = EventHarness(MotionDesignLanes(session: session), size: Self.size)
        try await harness.settle()

        // Well above the line at 3 s, still in the graph.
        let line = onLine(session, at: 3)
        try await harness.click(at: CGPoint(x: line.x, y: line.y - 80))
        #expect(abs(session.playhead - 3) <= session.secondsPerPoint)
        #expect(points(session) == 1)
        #expect(session.selectedPoint == nil)
    }

    @Test func aClickOnTheLineAddsASelectedMarkerThere() async throws {
        let session = try session()
        defer { session.end() }
        let harness = EventHarness(MotionDesignLanes(session: session), size: Self.size)
        try await harness.settle()

        try await harness.click(at: onLine(session, at: 4))
        #expect(points(session) == 1)
        let added = try #require(session.selectedPoint)
        #expect(abs(added.time.seconds - 4) <= session.secondsPerPoint)
        #expect(abs(session.playhead - 4) <= session.secondsPerPoint)
    }

    @Test func hoveringSkimsWhileSkimmingIsOn() async throws {
        let defaults = UserDefaults.standard
        let remembered = defaults.object(forKey: Preferences.motionDesignerSkimming)
        defer { defaults.set(remembered, forKey: Preferences.motionDesignerSkimming) }
        let session = try session()
        defer { session.end() }
        // Skimming shows a frame only once the player has an item: here ten
        // seconds of nothing.
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1)))
        let player = session.playback.player
        player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
        // Its time jumps to zero as it becomes ready, and the playhead
        // follows the player's jumps; the editor's player is ready long
        // before anyone skims, so the playhead is placed only after that.
        for _ in 0..<200 where player.currentItem?.status != .readyToPlay { try await Task.sleep(for: .milliseconds(10)) }
        session.seek(to: 2)
        session.skims = true
        let harness = EventHarness(MotionDesignLanes(session: session), size: Self.size)
        try await harness.settle()
        let playhead = session.playhead

        // Over the graph at 4 s: the monitor shows 4 s, the playhead stays.
        harness.mouse(.mouseMoved, at: CGPoint(x: onLine(session, at: 4).x, y: 150))
        try await harness.settle()
        let skimmed = try #require(session.playback.skimTime)
        #expect(abs(skimmed.seconds - 4) <= session.timeline.frameDuration.seconds)
        #expect(abs(session.playhead - playhead) < 1e-6)
        #expect(abs(playhead - 2) < 1e-6)

        // Turned off, the skim ends and hovering shows nothing.
        session.skims = false
        #expect(session.playback.skimTime == nil)
        harness.mouse(.mouseMoved, at: CGPoint(x: onLine(session, at: 5).x, y: 150))
        try await harness.settle()
        #expect(session.playback.skimTime == nil)
    }

    @Test func arrowsMoveThePlayheadNotTheSelectedClip() async throws {
        let session = try session()
        defer { session.end() }
        let piece = session.run.pieces[0]
        session.selectedPieceID = piece.id
        let harness = EventHarness(MotionDesignView(session: session, onDone: {}, onCancel: {}), size: CGSize(width: 1100, height: 600))
        try await harness.settle()

        harness.key(code: 124, characters: "\u{F703}")
        try await harness.settle()
        #expect(abs(session.playhead - (2 + session.timeline.frameDuration.seconds)) < 1e-6)
        #expect(session.run.pieces[0].span == piece.span)
        #expect(session.selectedPieceID == piece.id)
    }

    @Test func commandZUndoesAndShiftCommandZRedoes() async throws {
        let session = try session()
        defer { session.end() }
        let opened = session.run
        session.addMarker(toPiece: session.run.pieces[0].id, atTime: 4)
        let marked = session.run
        let harness = EventHarness(MotionDesignView(session: session, onDone: {}, onCancel: {}), size: CGSize(width: 1100, height: 600))
        try await harness.settle()

        harness.key(code: 6, characters: "z", flags: .command)
        try await harness.settle()
        #expect(session.run == opened)
        harness.key(code: 6, characters: "z", flags: [.command, .shift])
        try await harness.settle()
        #expect(session.run == marked)
    }

    /// Dragging in empty space picks the points it reaches round, and moves
    /// nothing; dragging one of them then moves both.
    @Test func aLassoPicksPointsAndTheyMoveTogether() async throws {
        let session = try session()
        defer { session.end() }
        let piece = session.run.pieces[0].id
        let a = try #require(session.addMarker(toPiece: piece, atTime: 3))
        let b = try #require(session.addMarker(toPiece: piece, atTime: 5))
        let before = session.run
        let harness = EventHarness(MotionDesignLanes(session: session), size: Self.size)
        try await harness.settle()

        let from = CGPoint(x: onLine(session, at: 2.5).x, y: onLine(session, at: 6).y - 4)
        let to = CGPoint(x: onLine(session, at: 5.5).x, y: onLine(session, at: 2).y + 4)
        try await harness.press(at: from, dragTo: to)
        harness.mouse(.leftMouseUp, at: to)
        try await harness.settle(250)
        #expect(session.pickedPointIDs == [a, b])
        #expect(session.run == before)

        let grab = onLine(session, at: 3)
        try await harness.press(at: grab, dragTo: CGPoint(x: grab.x + 20, y: grab.y))
        harness.mouse(.leftMouseUp, at: CGPoint(x: grab.x + 20, y: grab.y))
        try await harness.settle(250)
        func time(_ id: UUID) -> Double {
            session.run.piece(holdingPoint: id).map { session.run.pieces[$0.piece].map.points[$0.point].time.seconds } ?? .nan
        }
        let moved = 20 * session.secondsPerPoint
        #expect(abs(time(a) - (3 + moved)) <= 2 * session.secondsPerPoint)
        #expect(abs(time(b) - (5 + moved)) <= 2 * session.secondsPerPoint)
        #expect(session.pickedPointIDs == [a, b])
    }
}
