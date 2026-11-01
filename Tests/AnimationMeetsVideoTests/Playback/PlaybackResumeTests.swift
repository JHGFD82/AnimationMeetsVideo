import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Where a paused swap puts its new item (`PlaybackModel.resumeTime`).
@MainActor
@Suite struct PlaybackResumeTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    /// With no item the player's time is invalid; an item swapped in at it
    /// never drew ("asked nan s" in the log). The playhead stands in.
    @Test func withoutAnItemASwapResumesAtThePlayhead() {
        let playback = PlaybackModel()
        playback.showTimeline(from: seconds(3))
        #expect(!playback.player.currentTime().isNumeric)
        #expect(playback.resumeTime == seconds(3))
    }

    @Test func anItemLetGoResumesAtThePlayhead() {
        let playback = PlaybackModel()
        playback.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        playback.clearItem()
        playback.showTimeline(from: seconds(1.5))
        #expect(playback.resumeTime == seconds(1.5))
    }
}
