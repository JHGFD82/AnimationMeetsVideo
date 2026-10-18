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
            refreshStill()
        }
    }
    /// Whether the viewer draws motion blur at all. Off, frames are drawn
    /// without it, paused or playing; export and renders never are.
    var motionBlurInPreview: Bool {
        didSet {
            UserDefaults.standard.set(motionBlurInPreview, forKey: Self.motionBlurKey)
            drawingOptions.update(motionBlurInPreview: motionBlurInPreview)
        }
    }
    /// What the compositor is asked while it plays (see `DrawingOptions`).
    let drawingOptions = DrawingOptions()
    /// The size it is drawing at now, which Auto changes while playing.
    private(set) var level: PreviewLevel = .full
    /// Hears from the compositor how long each frame took.
    let meter = RenderMeter()
    /// The layers' volumes, which the player's audio taps read as they
    /// play; the editor replaces them as volumes are edited.
    let mixCurves = MixCurves()
    /// How loud the mix is, measured by the same taps, for the meter.
    let mixMeter = MixLevelMeter()
    /// Plays the mix under the playhead as it is moved while paused.
    let scrubAudio = ScrubAudio()
    /// Plays the mix at the Tape Scrubber's speed while its window is open.
    let tapeScrub = TapeScrub()
    /// True while the tape scrubber moves the playhead, which the
    /// timeline's parked playhead then follows.
    private(set) var isTapeScrubbing = false
    @ObservationIgnored private var tapeFollower: Task<Void, Never>?
    @ObservationIgnored private var isHoldingTape = false
    /// The device the sound plays out of, as last routed.
    @ObservationIgnored private var outputUID: String?
    /// The paused frame drawn at full size, shown over the player while it
    /// draws smaller. Auto keeps playing's level while paused, so pressing
    /// play doesn't swap the composition; this is what keeps paused frames
    /// sharp. Nil while playing, scrubbing, or drawing at full size.
    private(set) var still: CGImage?
    /// The paused frame drawn from the newest edit, while the player still
    /// holds the composition from before it. Shown over everything until
    /// the player item is swapped, so the viewer follows a drag without
    /// swapping the item at every step.
    private(set) var liveFrame: CoverPicture?
    /// What the viewer shows over the player, if anything.
    var cover: CoverPicture? { liveFrame ?? still.map(CoverPicture.image) }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var governor = PreviewGovernor()
    /// The current item's composition at full size; each level is drawn
    /// from a scaled copy of it.
    @ObservationIgnored private var composed: ComposedTimeline?
    @ObservationIgnored private var frameRate: Double = 0
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var stillTask: Task<Void, Never>?
    @ObservationIgnored private let liveRenderer = LiveFrameRenderer()
    @ObservationIgnored private var liveGovernor = LiveGovernor()
    @ObservationIgnored private var preferencesTask: Task<Void, Never>?
    @ObservationIgnored private var deviceObservation: DeviceListObservation?

    private static let qualityKey = Preferences.previewQuality
    private static let motionBlurKey = Preferences.motionBlurInPreview

    init() {
        let player = AVPlayer()
        // Media is local, so there's no network to wait on: play starts at
        // once from what `prerollIfPaused` has already decoded, instead of
        // waiting for the player to judge its buffer full enough.
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        quality = UserDefaults.standard.string(forKey: Self.qualityKey).flatMap(PreviewQuality.init(rawValue:)) ?? .auto
        let blur = UserDefaults.standard.object(forKey: Self.motionBlurKey) as? Bool ?? true
        motionBlurInPreview = blur
        drawingOptions.update(motionBlurInPreview: blur)
        beatClicks = BeatClickPlayer(player: player)
        liveRenderer.onFrame = { [weak self] image, seconds, interactive in self?.receiveLiveFrame(image, seconds: seconds, interactive: interactive) }
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
        // Each new item is prerolled once it can be.
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor in self?.watchStatus(of: item) }
        }
        // The Settings window writes the same defaults; follow it.
        preferencesTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                guard let self else { return }
                self.readPreferences()
            }
        }
        // A chosen device plugged in or out moves the sound to it or back
        // to the system's default.
        routeSound()
        deviceObservation = AudioDevices.observe { [weak self] in self?.routeSound() }
    }

    /// Sends the sound and the beat tick to the devices chosen in Settings.
    /// Setting only what differs keeps playback from stopping to reroute
    /// on every unrelated change.
    private func routeSound() {
        let playback = AudioDevices.playbackUID
        outputUID = playback
        if player.audioOutputDeviceUniqueID != playback { player.audioOutputDeviceUniqueID = playback }
        beatClicks.outputDeviceUID = AudioDevices.clicksUID
        tapeScrub.route(deviceUID: playback)
    }

    /// Takes up a quality or motion blur set elsewhere, such as in the
    /// Settings window. Setting only what differs keeps this from writing
    /// the defaults back, and from redrawing on every unrelated change.
    private func readPreferences() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.qualityKey).flatMap(PreviewQuality.init(rawValue:)), stored != quality {
            quality = stored
        }
        if let stored = defaults.object(forKey: Self.motionBlurKey) as? Bool, stored != motionBlurInPreview {
            motionBlurInPreview = stored
        }
        routeSound()
    }

    private func watchStatus(of item: AVPlayerItem?) {
        itemStatusObservation = item?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in self?.prerollIfPaused() }
        }
    }

    /// Fills the player's pipeline from the paused position, so pressing
    /// play shows frames at once. Done after every pause, seek and new
    /// item; any seek or play cancels it.
    private func prerollIfPaused() {
        guard !isPlaying, !isSeeking, player.rate == 0,
              player.status == .readyToPlay, player.currentItem?.status == .readyToPlay
        else { return }
        player.cancelPendingPrerolls()
        player.preroll(atRate: 1)
    }

    /// Gives `item` the composition at the current level, and keeps
    /// `composed` to draw the other levels from.
    func prepare(_ item: AVPlayerItem, with composed: ComposedTimeline, frameRate: Double) {
        self.composed = composed
        self.frameRate = frameRate
        item.videoComposition = composed.videoComposition(scaledBy: level.scale)
        item.audioMix = composed.audioMix(curves: mixCurves, meter: mixMeter)
        mixMeter.reset()
        scrubAudio.setComposition(composed, curves: mixCurves)
        tapeScrub.setComposition(composed, curves: mixCurves)
        // The old still stays until the new one is drawn (or turns out not
        // to be needed): clearing it here would uncover the player's
        // smaller picture for a moment on every rebuild.
        refreshStill()
    }

    /// Draws the paused frame from `composed`, the newest edit, over the
    /// viewer. Does nothing while playing or seeking, which show the
    /// player itself.
    ///
    /// With `interactive` (a value is being dragged) the frame is drawn
    /// at a size the renderer keeps up with, stepping down to a quarter
    /// of the pixels when frames take too long and back up when they
    /// don't (`LiveGovernor`); the frame after the drag is full size.
    ///
    /// `structure` is that of the project `composed` was built from
    /// (`EditingProject.structure`): the frame then keeps what it was drawn
    /// from, so a later edit of values alone can be drawn without a build
    /// (`redrawLive`).
    func showLive(_ composed: ComposedTimeline, interactive: Bool = false, structure: EditingProject? = nil) {
        guard !isPlaying, !isSeeking, player.currentItem != nil else { return }
        if !interactive { liveGovernor.reset() }
        let scale = interactive ? min(level.scale, liveGovernor.level.scale) : level.scale
        liveRenderer.submit(.init(
            composed: composed, scale: scale, time: player.currentTime(), interactive: interactive, structure: structure
        ))
    }

    /// Draws the paused frame again with `project`'s values, from the frame
    /// last drawn from a build, when only values have changed since
    /// (`structure` is `project.structure`). Then only the clips' new values
    /// are drawn, in a few milliseconds, with nothing built or decoded, as
    /// a drag of a value wants. False when it can't (playing, the playhead
    /// moved, the structure changed, a render shows there): the timeline
    /// is to be built as usual.
    func redrawLive(_ project: EditingProject, structure: EditingProject, interactive: Bool) -> Bool {
        guard !isPlaying, !isSeeking, player.currentItem != nil,
              liveRenderer.redraw(with: project, structure: structure, time: player.currentTime(), interactive: interactive)
        else { return false }
        liveRedraws += 1
        return true
    }

    /// How many frames `redrawLive` has drawn, so a build begun before one
    /// doesn't put its older picture over it.
    @ObservationIgnored private(set) var liveRedraws = 0

    private func receiveLiveFrame(_ picture: CoverPicture, seconds: Double, interactive: Bool) {
        guard !isPlaying, !isSeeking else { return }
        if interactive { liveGovernor.record(seconds: seconds) }
        liveFrame = picture
        // A still of what was edited away mustn't show once this goes.
        clearStill()
    }

    /// Lets go of the live frame, so the player shows. Done by playing and
    /// scrubbing, and when there is nothing to show.
    func clearLive() {
        liveRenderer.cancel()
        if liveFrame != nil { liveFrame = nil }
    }

    private func playStateChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        // The periodic ticks only come every 30th of a second; the parked
        // playhead should land exactly where playing stopped. Not while a
        // seek is in flight: its target is already set, and the player
        // hasn't reached it yet.
        if !playing, !isSeeking { currentTime = player.currentTime() }
        isPlaying = playing
        if playing {
            clearLive()
            // Playing lets go of the scrub engine and its device.
            scrubAudio.stop()
            if isTapeScrubbing { stopTape() }
        }
        drawingOptions.update(isPlaying: playing)
        sampling?.cancel()
        sampling = nil
        if playing {
            governor.startPlaying(at: CACurrentMediaTime())
            sampling = Task { [weak self] in await self?.samplePlayback() }
        } else {
            governor.stopPlaying()
        }
        applyLevel()
        if playing {
            clearStill()
        } else {
            refreshStill()
            prerollIfPaused()
        }
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
        drawingOptions.update(isQuarterSize: wanted == .quarter)
        if let item = player.currentItem, let composed {
            item.videoComposition = composed.videoComposition(scaledBy: wanted.scale)
        }
        refreshStill()
        prerollIfPaused()
    }

    /// Draws the paused frame at full size when Auto is drawing smaller,
    /// once the player has settled on it.
    private func refreshStill() {
        stillTask?.cancel()
        guard !isPlaying, !isSeeking, quality == .auto, level != .full,
              let composed, composed.hasPictures, let videoComposition = composed.videoComposition,
              player.currentItem != nil
        else {
            clearStill()
            return
        }
        let time = player.currentTime()
        stillTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: composed.composition)
            generator.videoComposition = videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try? await generator.image(at: time).image
            guard let self, !Task.isCancelled, !self.isPlaying, !self.isSeeking,
                  CMTimeCompare(self.player.currentTime(), time) == 0
            else { return }
            self.still = image
        }
    }

    private func clearStill() {
        stillTask?.cancel()
        stillTask = nil
        if still != nil { still = nil }
    }

    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeek: CMTime?

    /// Scrub-friendly seek: only one seek is ever in flight, and a newer
    /// target replaces any that was queued behind it, so dragging the
    /// playhead doesn't pile up zero-tolerance seeks.
    func seek(to time: CMTime) {
        if isTapeScrubbing { stopTape() }
        tapeScrub.cue(time.seconds)
        move(to: time)
    }

    /// Moves the playhead and seeks the player, playing a grain of the
    /// mix there unless the tape scrubber is playing it already.
    private func move(to time: CMTime, playsGrain: Bool = true) {
        if playsGrain, !isPlaying, UserDefaults.standard.object(forKey: Preferences.scrubAudio) as? Bool ?? true {
            // From the start of its frame, so every move within one frame
            // asks for the same grain, which plays once.
            let seconds = frameRate > 0 ? (time.seconds * frameRate + 1e-6).rounded(.down) / frameRate : time.seconds
            scrubAudio.play(at: seconds, deviceUID: outputUID)
        }
        currentTime = time
        pendingSeek = time
        clearLive()
        clearStill()
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
        refreshStill()
        prerollIfPaused()
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

    // MARK: Tape scrubbing

    /// Readies the tape scrubber on the playback device, at the playhead,
    /// for when its dial is grabbed.
    func openTape() {
        tapeScrub.open(deviceUID: outputUID)
        tapeScrub.cue(currentTime.seconds)
    }

    /// Lets the tape scrubber's engine go, its window closed.
    func closeTape() {
        stopTape()
        tapeScrub.close()
    }

    /// Runs the tape at `rate` (times normal speed, backwards when
    /// negative, still at 0) while the dial is held. The playhead follows
    /// it.
    func scrubTape(rate: Double) {
        isHoldingTape = true
        if !isTapeScrubbing {
            if isPlaying {
                player.pause()
                tapeScrub.cue(player.currentTime().seconds)
            }
            isTapeScrubbing = true
            tapeFollower = Task { [weak self] in await self?.followTape() }
        }
        tapeScrub.setRate(rate)
    }

    /// Lets go of the dial: the tape comes to rest.
    func releaseTape() {
        isHoldingTape = false
        tapeScrub.setRate(0)
    }

    /// Moves the playhead to where the tape is, each screen refresh or so,
    /// until the dial is let go and the tape comes to rest; then onto the
    /// start of the frame it stopped in, where the tape is put too.
    private func followTape() async {
        while !Task.isCancelled {
            let time = CMTime(seconds: tapeScrub.position, preferredTimescale: 600_000)
            if !isHoldingTape, tapeScrub.isStopped {
                let seconds = frameRate > 0 ? (time.seconds * frameRate + 1e-6).rounded(.down) / frameRate : time.seconds
                let frame = CMTime(seconds: seconds, preferredTimescale: 600_000)
                tapeScrub.cue(frame.seconds)
                move(to: frame, playsGrain: false)
                tapeFollower = nil
                isTapeScrubbing = false
                return
            }
            if CMTimeCompare(time, currentTime) != 0 { move(to: time, playsGrain: false) }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    /// Stops the tape where it is, at once, for another move of the
    /// playhead.
    private func stopTape() {
        isHoldingTape = false
        tapeScrub.setRate(0)
        tapeFollower?.cancel()
        tapeFollower = nil
        isTapeScrubbing = false
    }
}
