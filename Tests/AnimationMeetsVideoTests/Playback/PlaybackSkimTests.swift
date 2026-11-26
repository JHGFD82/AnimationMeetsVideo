import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Skimming the timeline: the player goes where the pointer is and back,
/// and the playhead stays where it was parked.
@MainActor
@Suite(.serialized) struct PlaybackSkimTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    /// A model playing a 4 s, 24 fps movie, parked at `parked`.
    private func makePlayback(parkedAt parked: Double) async throws -> (PlaybackModel, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-timeline-skim-\(UUID().uuidString).mov")
        try await writeMovie(to: url, segments: [(0, 48), (255, 48)])
        let playback = PlaybackModel()
        playback.player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: url)))
        playback.seek(to: seconds(parked))
        try await waitForPlayer(playback, at: parked)
        return (playback, url)
    }

    /// Waits for the player to get to `time`, as its seeks finish.
    private func waitForPlayer(_ playback: PlaybackModel, at time: Double, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil("the player to reach \(time) s", every: .milliseconds(10), sourceLocation: sourceLocation) {
            abs(playback.player.currentTime().seconds - time) < 0.001
        }
    }

    @Test func skimmingShowsThePointersTimeAndLeavesThePlayhead() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        playback.skim(to: seconds(2.5))
        #expect(playback.skimTime == seconds(2.5))
        try await waitForPlayer(playback, at: 2.5)
        // The player's jump to the skim isn't taken for the playhead's.
        try await Task.sleep(for: .milliseconds(100))
        #expect(playback.currentTime == seconds(1))

        playback.endSkim()
        #expect(playback.skimTime == nil)
        try await waitForPlayer(playback, at: 1)
        #expect(playback.currentTime == seconds(1))
    }

    @Test func movingThePlayheadEndsTheSkim() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        playback.skim(to: seconds(3))
        playback.seek(to: seconds(2))

        #expect(playback.skimTime == nil)
        try await waitForPlayer(playback, at: 2)
        #expect(playback.currentTime == seconds(2))
    }

    @Test func playingStartsFromTheFrameSkimmedTo() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }

        playback.skim(to: seconds(2))
        playback.togglePlayback()
        defer { playback.player.pause() }

        #expect(playback.skimTime == nil)
        #expect(playback.currentTime == seconds(2))
        try await waitUntil("the player to reach 2 s", every: .milliseconds(10)) { playback.player.currentTime().seconds >= 2 }
    }

    @Test func skimmingWaitsOutPlaying() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        playback.togglePlayback()
        defer { playback.player.pause() }
        try await waitUntil("playback to start", every: .milliseconds(10)) { playback.isPlaying }

        playback.skim(to: seconds(3))

        #expect(playback.skimTime == nil)
    }

    /// A drag's seeks don't wait behind a preroll: the player is prerolled
    /// once the playhead rests, not after each seek of the drag.
    @Test func prerollingWaitsForThePlayheadToRest() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        try await Task.sleep(for: PlaybackModel.prerollRest * 2)
        let before = playback.prerolls

        for frame in 13...36 {
            playback.seek(to: CMTime(value: Int64(frame), timescale: 24))
            try await Task.sleep(for: .milliseconds(16))
        }
        #expect(playback.prerolls == before)

        // Once it rests, one preroll: waited for rather than slept, so a
        // busy machine running the other suites doesn't fail it.
        try await waitUntil("the player to be prerolled", every: .milliseconds(10)) { playback.prerolls > before }
        try await Task.sleep(for: PlaybackModel.prerollRest)
        #expect(playback.prerolls == before + 1)
        try await waitForPlayer(playback, at: 1.5)
    }

    /// A fast drag seeks roughly, the playhead staying exactly where it was
    /// moved, and the player lands exactly where the drag stopped.
    @Test func aFastDragLandsExactlyOnceItRests() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }

        // Two frames every 10 ms: eight times normal speed.
        for frame in stride(from: 12, through: 90, by: 2) {
            let time = CMTime(value: Int64(frame), timescale: 24)
            playback.seek(to: time)
            #expect(playback.currentTime == time)
            try await Task.sleep(for: .milliseconds(10))
        }
        let last = CMTime(value: 90, timescale: 24)
        try await waitForPlayer(playback, at: last.seconds)
        // Landed, its ticks are the playhead's again, and agree.
        try await Task.sleep(for: .milliseconds(100))
        #expect(playback.currentTime == last)
        #expect(playback.shownFrame() == nil || abs((playback.shownFrame()?.time.seconds ?? 0) - last.seconds) < 0.001)
    }

    /// Play straight after a fast drag starts from the frame it stopped on,
    /// not from near it.
    @Test func playingAfterAFastDragStartsExactly() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }

        for frame in stride(from: 12, through: 60, by: 2) {
            playback.seek(to: CMTime(value: Int64(frame), timescale: 24))
            try await Task.sleep(for: .milliseconds(10))
        }
        playback.togglePlayback()
        defer { playback.player.pause() }
        try await waitUntil("playback to start", every: .milliseconds(5)) { playback.isPlaying }
        // Played on from near 2.5 s, it would still be short of it.
        try await Task.sleep(for: .milliseconds(150))
        let played = playback.player.currentTime().seconds
        #expect(played >= 2.5 && played < 3.2, "at \(played) s")
    }

    @Test func showingAnotherTimelineLetsTheSkimGoAndParksThePlayhead() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        playback.skim(to: seconds(3))
        playback.showTimeline(from: seconds(2))
        #expect(playback.skimTime == nil)
        #expect(playback.currentTime == seconds(2))

        // The item swapped in for the other timeline isn't sent back to the
        // playhead or skim of the one before.
        playback.player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: url)))
        await playback.player.seek(to: seconds(2), toleranceBefore: .zero, toleranceAfter: .zero)
        playback.endSkim()
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(playback.player.currentTime().seconds - 2) < 0.001)
        #expect(playback.currentTime == seconds(2))
    }
}
