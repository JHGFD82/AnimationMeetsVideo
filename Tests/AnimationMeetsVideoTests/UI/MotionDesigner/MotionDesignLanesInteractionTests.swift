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
}
