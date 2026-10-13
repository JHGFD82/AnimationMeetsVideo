import AppKit
import AVFoundation
import CoreMedia
import Observation
import SwiftUI

/// Shared player so the main viewer and a synced external window stay
/// perfectly in sync — both observe the same `AVPlayer` instance.
@MainActor
@Observable
final class PlaybackModel {
    let player: AVPlayer
    /// Blips on the timeline's beat markers during playback.
    let beatClicks: BeatClickPlayer
    private(set) var currentTime: CMTime = .zero
    private(set) var isPlaying = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    init() {
        let player = AVPlayer()
        self.player = player
        beatClicks = BeatClickPlayer(player: player)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeek: CMTime?

    /// Scrub-friendly seek: only one seek is ever in flight, and a newer
    /// target replaces any that was queued behind it, so dragging the
    /// playhead doesn't pile up zero-tolerance seeks.
    func seek(to time: CMTime) {
        currentTime = time
        pendingSeek = time
        guard !isSeeking else { return }
        isSeeking = true
        Task { await drainSeeks() }
    }

    private func drainSeeks() async {
        while let target = pendingSeek {
            pendingSeek = nil
            _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        isSeeking = false
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            return
        }
        if let item = player.currentItem, item.duration.isNumeric,
           CMTimeCompare(player.currentTime(), item.duration) >= 0 {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }
}
