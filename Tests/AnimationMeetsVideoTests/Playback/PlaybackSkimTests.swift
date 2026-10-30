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
        #expect(await playerReaches(playback, parked))
        return (playback, url)
    }

    /// Waits for the player to get to `time`, as its seeks finish.
    private func playerReaches(_ playback: PlaybackModel, _ time: Double) async -> Bool {
        for _ in 0..<300 {
            if abs(playback.player.currentTime().seconds - time) < 0.001 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func skimmingShowsThePointersTimeAndLeavesThePlayhead() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        playback.skim(to: seconds(2.5))
        #expect(playback.skimTime == seconds(2.5))
        #expect(await playerReaches(playback, 2.5))
        // The player's jump to the skim isn't taken for the playhead's.
        try await Task.sleep(for: .milliseconds(100))
        #expect(playback.currentTime == seconds(1))

        playback.endSkim()
        #expect(playback.skimTime == nil)
        #expect(await playerReaches(playback, 1))
        #expect(playback.currentTime == seconds(1))
    }

    @Test func movingThePlayheadEndsTheSkim() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        playback.skim(to: seconds(3))
        playback.seek(to: seconds(2))

        #expect(playback.skimTime == nil)
        #expect(await playerReaches(playback, 2))
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
        var reached = false
        for _ in 0..<300 where !reached {
            reached = playback.player.currentTime().seconds >= 2
            if !reached { try? await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(reached)
    }

    @Test func skimmingWaitsOutPlaying() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        playback.togglePlayback()
        defer { playback.player.pause() }
        for _ in 0..<300 where !playback.isPlaying { try? await Task.sleep(for: .milliseconds(10)) }

        playback.skim(to: seconds(3))

        #expect(playback.skimTime == nil)
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
