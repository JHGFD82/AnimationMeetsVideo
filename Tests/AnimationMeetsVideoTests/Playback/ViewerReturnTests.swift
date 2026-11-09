import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Going back out of a nested timeline with the real player and pipeline:
/// the viewer shows the picture it was left with at once, and the item it
/// had comes back without a build.
@MainActor
@Suite(.serialized) struct ViewerReturnTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    private func eventually(_ what: String, within limit: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting: \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func goingBackOutShowsTheParentsPictureAtOnce() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let parent = fixture.timelineID
        try await fixture.addClip(luma: 40, frames: 96)
        let nested = fixture.project.addTimeline(
            name: "Nested", frameSize: CGSize(width: 128, height: 72), frameRate: 24, colorSpace: .rec709
        )
        try await fixture.addClip(luma: 220, frames: 48, to: nested)
        fixture.project.embedTimeline(nested, intoTimeline: parent)
        let project = fixture.project
        func source(_ timelineID: UUID) -> ViewerSource {
            ViewerSource(project: project, renderProject: project, timelineID: timelineID)
        }

        let playback = PlaybackModel()
        let pipeline = ViewerPipeline(playback: playback, renderer: nil)
        let parked = seconds(2.5)
        // As the editor surface does: the playhead first, then the pipeline.
        playback.showTimeline(from: parked)
        pipeline.send(.appeared(source(parent), at: parked))
        try await eventually("the parent shown") { pipeline.swapsApplied == 1 }
        let parentPicture = try #require(playback.display.buffer)

        playback.showTimeline(from: .zero)
        pipeline.send(.timelineChanged(source(nested), at: .zero))
        try await eventually("the nested timeline shown") { pipeline.swapsApplied == 2 }
        let nestedPicture = playback.display.buffer
        #expect(nestedPicture !== parentPicture)

        let back = ContinuousClock.now
        playback.showTimeline(from: parked)
        pipeline.send(.timelineChanged(source(parent), at: parked))
        try await eventually("the event handled") { pipeline.eventsHandled == pipeline.eventsSent }
        // On screen as soon as the switch is handled, before the item.
        let shownAtOnce = playback.display.buffer === parentPicture
        #expect(shownAtOnce)
        try await eventually("the parent swapped back in") { pipeline.swapsApplied == 3 }
        let elapsed = ContinuousClock.now - back
        #expect(pipeline.buildsStarted == 2)
        #expect(pipeline.parkedBuildsUsed == 1)
        let playerTime = playback.player.currentTime().seconds
        #expect(abs(playerTime - 2.5) < 0.001)
        print("ViewerReturnTests: parent swapped back in after \(elapsed)")
    }
}
