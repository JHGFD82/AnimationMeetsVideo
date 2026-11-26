import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The scrub cache (docs/rendering.md, "Scrub cache"): parked, the frames
/// around the playhead are read into memory, and a fast drag over them
/// shows them without seeking the player, which lands exactly once the
/// drag rests. A 4 s, 24 fps clip on a 128 by 72 timeline.
@MainActor
@Suite(.serialized) struct ScrubCacheTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    private func parked(at time: Double) async throws -> (PlaybackModel, DrawingFixture) {
        var fixture = try DrawingFixture()
        try await fixture.addClip(luma: 120, frames: 96)
        let composed = try await fixture.build(forPreview: true)
        let playback = PlaybackModel()
        playback.scrubCache.settleSeconds = 0
        let swapped = await playback.swap(to: composed, key: StructureKey(project: fixture.project), frameRate: 24, at: seconds(time))
        #expect(swapped)
        return (playback, fixture)
    }

    @Test func parkedItReadsTheFramesAroundThePlayhead() async throws {
        let (playback, fixture) = try await parked(at: 1)
        defer { fixture.cleanUp() }
        // From the start (3 s before is before it) to 4 s: all 96 frames.
        try await waitUntil("the cache to fill", every: .milliseconds(20)) { playback.scrubCache.count == 96 }
        #expect(playback.scrubCache.frame(at: seconds(3.5)) != nil)
        #expect(playback.scrubCache.keptBytes > 0)
    }

    @Test func aFastDragOverKeptFramesShowsThemAndLandsExactly() async throws {
        let (playback, fixture) = try await parked(at: 1)
        defer { fixture.cleanUp() }
        try await waitUntil("the cache to fill", every: .milliseconds(20)) { playback.scrubCache.count == 96 }
        // Two frames every 10 ms: eight times normal speed.
        for frame in stride(from: 26, through: 70, by: 2) {
            playback.seek(to: CMTime(value: Int64(frame), timescale: 24))
            try await Task.sleep(for: .milliseconds(10))
        }
        let last = CMTime(value: 70, timescale: 24)
        // Shown from the cache. The first moves, before the pace told a
        // fast drag, seeked; the rest didn't, so the player is still near
        // where the drag began.
        #expect(playback.display.buffer === playback.scrubCache.frame(at: last))
        #expect(playback.player.currentTime().seconds < 1.6)
        #expect(playback.currentTime == last)
        // Rested, it lands exactly.
        try await waitUntil("the player to land", every: .milliseconds(10)) {
            abs(playback.player.currentTime().seconds - last.seconds) < 0.001
        }
    }

    @Test func anEditLetsGoOfTheFrames() async throws {
        let (playback, fixture) = try await parked(at: 1)
        defer { fixture.cleanUp() }
        try await waitUntil("the cache to fill", every: .milliseconds(20)) { playback.scrubCache.count > 0 }
        playback.showValues([:])
        #expect(playback.scrubCache.count == 0)
    }
}
