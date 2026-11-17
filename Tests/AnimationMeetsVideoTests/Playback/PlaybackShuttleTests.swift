import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// J, K and L: playing backward and forward, faster with each press, and
/// stopping (`PlaybackModel.shuttle`, `pause`).
@MainActor
@Suite(.serialized) struct PlaybackShuttleTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    /// A model with a 4 s, 24 fps movie, parked at `parked`.
    private func makePlayback(parkedAt parked: Double) async throws -> (PlaybackModel, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-shuttle-\(UUID().uuidString).mov")
        try await writeMovie(to: url, segments: [(0, 48), (255, 48)])
        let playback = PlaybackModel()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        playback.player.replaceCurrentItem(with: item)
        try await waitUntil("the item to be ready", every: .milliseconds(10)) { item.status == .readyToPlay }
        playback.seek(to: seconds(parked))
        try await waitUntil("the player to reach \(parked) s", every: .milliseconds(10)) {
            abs(playback.player.currentTime().seconds - parked) < 0.001
        }
        return (playback, url)
    }

    private func waitForPlaying(_ playback: PlaybackModel, _ playing: Bool = true) async throws {
        try await waitUntil(playing ? "playing" : "stopped", every: .milliseconds(10)) { playback.isPlaying == playing }
    }

    @Test func nothingToPlayDoesNothing() {
        let playback = PlaybackModel()
        #expect(!playback.shuttle(forward: true))
        #expect(!playback.shuttle(forward: false))
        #expect(!playback.pause())
    }

    @Test func lPlaysForwardFasterEachTimeUpToEight() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try #require(playback.player.currentItem)

        #expect(playback.shuttle(forward: true))
        #expect(playback.player.rate == 1)
        try await waitForPlaying(playback)
        guard item.canPlayFastForward else { return }
        for expected: Float in [2, 4, 8, 8] {
            playback.shuttle(forward: true)
            #expect(playback.player.rate == expected)
            #expect(playback.shuttleRate == expected)
        }
        #expect(playback.pause())
        try await waitForPlaying(playback, false)
        #expect(playback.shuttleRate == 1)
    }

    @Test func jTurnsAroundAtNormalSpeed() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try #require(playback.player.currentItem)

        playback.shuttle(forward: true)
        try await waitForPlaying(playback)
        playback.shuttle(forward: true)
        guard item.canPlayReverse else { return }
        #expect(playback.shuttle(forward: false))
        #expect(playback.player.rate == -1)
        playback.pause()
        try await waitForPlaying(playback, false)
    }

    @Test func jAtTheStartDoesNothing() async throws {
        let (playback, url) = try await makePlayback(parkedAt: 0)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!playback.shuttle(forward: false))
        #expect(playback.player.rate == 0)
    }
}
