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
    /// The size the viewer is asked to draw at.
    var quality: PreviewQuality {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityKey)
            applyLevel()
        }
    }
    /// The size it is drawing at now, which Auto changes while playing.
    private(set) var level: PreviewLevel = .full
    /// Hears from the compositor how long each frame took.
    let meter = RenderMeter()

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var governor = PreviewGovernor()
    /// The current item's composition at full size; each level is drawn
    /// from a scaled copy of it.
    @ObservationIgnored private var composed: ComposedTimeline?
    @ObservationIgnored private var frameRate: Double = 0
    @ObservationIgnored private var sampling: Task<Void, Never>?

    private static let qualityKey = "previewQuality"

    init() {
        let player = AVPlayer()
        self.player = player
        quality = UserDefaults.standard.string(forKey: Self.qualityKey).flatMap(PreviewQuality.init(rawValue:)) ?? .auto
        beatClicks = BeatClickPlayer(player: player)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.playStateChanged(playing) }
        }
    }

    /// Gives `item` the composition at the current level, and keeps
    /// `composed` to draw the other levels from.
    func prepare(_ item: AVPlayerItem, with composed: ComposedTimeline, frameRate: Double) {
        self.composed = composed
        self.frameRate = frameRate
        item.videoComposition = composed.videoComposition(scaledBy: level.scale)
    }

    private func playStateChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        sampling?.cancel()
        sampling = nil
        if playing {
            governor.startPlaying(at: CACurrentMediaTime())
            sampling = Task { [weak self] in await self?.samplePlayback() }
        } else {
            governor.stopPlaying()
        }
        applyLevel()
    }

    /// While playing, measures twice a second how many frames the compositor
    /// finished, for Auto to adjust the level.
    private func samplePlayback() async {
        _ = meter.drain()
        var last = CACurrentMediaTime()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let now = CACurrentMediaTime()
            let totals = meter.drain()
            defer { last = now }
            // No frames means nothing was drawn by the compositor (an empty
            // timeline, or the player stalled), which says nothing about speed.
            guard totals.frames > 0 else { continue }
            let sample = PreviewGovernor.Sample(
                time: now, framesPerSecond: Double(totals.frames) / (now - last),
                renderSeconds: totals.meanRenderSeconds
            )
            if governor.record(sample, frameRate: frameRate) { applyLevel() }
        }
    }

    /// Swaps the current item's composition when the level should change.
    private func applyLevel() {
        let wanted = quality.fixedLevel ?? governor.level
        guard wanted != level else { return }
        level = wanted
        if let item = player.currentItem, let composed {
            item.videoComposition = composed.videoComposition(scaledBy: wanted.scale)
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
