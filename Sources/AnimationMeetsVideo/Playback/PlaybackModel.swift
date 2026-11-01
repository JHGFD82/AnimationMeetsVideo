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
    /// Where the pointer skims the timeline while paused: the viewer (and
    /// the scrub sound) are there, and the playhead stays at `currentTime`.
    /// Nil when the timeline isn't skimmed. See docs/audio.md, "Scrubbing".
    private(set) var skimTime: CMTime?
    /// How many times the player's item was swapped for a new build while
    /// playing, after its seek and play. The playhead that follows the
    /// player binds as the item is replaced, before the seek, and binds
    /// again when this changes.
    private(set) var itemSwaps = 0
    /// The structure (`StructureKey`) of the project the player's item was
    /// built from, and whether any of it plays from a render. An edit that
    /// leaves the key the same is drawn by the item as it is, with the
    /// edit's values (`showValues`); a render, which holds the values it
    /// was made with, gives way to the clips it was made from.
    @ObservationIgnored private(set) var playedKey: StructureKey?
    @ObservationIgnored private(set) var playedUsesRenders = false
    /// The size the viewer is asked to draw at.
    var quality: PreviewQuality {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityKey)
            applyLevel()
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
    let drawingOptions = DrawingOptions(liveValues: LiveValues())
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
    /// The viewer's picture, its one painter (see `ViewerDisplay`).
    let display = ViewerDisplay()
    /// The project's values, which the compositor draws every frame with,
    /// paused or playing (see `LiveValues`); this player's own, so another
    /// window's player can follow another project.
    var liveValues: LiveValues { drawingOptions.liveValues }
    /// What the paused frame was drawn from, for drawing it again with new
    /// values, or at full size while Auto plays smaller.
    @ObservationIgnored private let capture = SourceCapture()
    @ObservationIgnored private let redrawer = FrameRedrawer()
    /// Bumped whenever a frame being drawn again stops being wanted (a
    /// seek, play, a new item), so it isn't shown when it is done.
    @ObservationIgnored private var redrawToken = 0
    /// The first frame of an item swapped in while playing fades in.
    @ObservationIgnored private var fadesNextFrame = false
    /// Set while an item is swapped in while playing, which pauses the
    /// player for a moment that isn't a pause.
    @ObservationIgnored private var isSwapping = false

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
    /// Draws the paused playhead's neighborhood ahead of playback.
    @ObservationIgnored private let prerenderer = PlayheadPrerenderer()
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
        redrawer.onFrame = { [weak self] buffer, token in self?.receiveRedrawn(buffer, token: token) }
        display.onOutputFrame = { [weak self] buffer, time in self?.receiveOutputFrame(buffer, at: time) }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                // A seek is a jump of time too: while the player is off
                // showing a skim, its time isn't the playhead's.
                guard let self, self.isPlaying || !self.playerIsSkimmed else { return }
                self.currentTime = time
            }
        }
        // The state as it is when this runs, not when it was observed: a
        // swap while playing pauses for a moment, which is over by then.
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.playStateChanged(self.player.timeControlStatus != .paused)
            }
        }
        // Each new item is prerolled once it can be, and shown.
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor in
                self?.watchStatus(of: item)
                self?.display.follow(item)
            }
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
    /// play shows frames at once. Done after every pause and new item, and
    /// once the playhead rests after a seek (`prerollRest`); any seek or
    /// play cancels it.
    private func prerollIfPaused() {
        guard !isPlaying, !isSeeking, player.rate == 0,
              player.status == .readyToPlay, player.currentItem?.status == .readyToPlay
        else { return }
        prerolls += 1
        player.cancelPendingPrerolls()
        player.preroll(atRate: 1)
        if let item = player.currentItem, let composition = item.asset as? AVComposition, let videoComposition = item.videoComposition {
            prerenderer.start(composition: composition, videoComposition: videoComposition, around: player.currentTime())
        }
    }

    /// Gives `item` the composition at the current level, and keeps
    /// `composed` to draw the other levels from.
    /// Has the playing item draw every stretch from its clips, not from
    /// its renders, which hold the values they were made with and can't
    /// follow a drag (`LiveValues`). Only the item's video composition
    /// changes, so the sound plays on and the picture doesn't blink. False
    /// when there is nothing to change.
    @discardableResult
    func playWithoutRenders() -> Bool {
        guard playedUsesRenders, let composed, let item = player.currentItem,
              composed.unrenderedVideoComposition != nil
        else { return false }
        playedUsesRenders = false
        item.videoComposition = composed.videoComposition(scaledBy: level.scale, withoutRenders: true)
        // Paused, the player draws its frame again from the clips.
        if !isPlaying { display.wake() }
        return true
    }

    /// Readies `item`, built from `composed`, to be swapped in (`swap`):
    /// its compositions at the current level, keeping what the paused frame
    /// is drawn from (`SourceCapture`), and the video output the viewer
    /// shows its frames through, in the compositor's own format.
    func prepare(_ item: AVPlayerItem, with composed: ComposedTimeline, key: StructureKey, frameRate: Double) {
        let composed = composed.capturing(into: capture)
        self.composed = composed
        item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: composed.viewerPixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: any Sendable],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]))
        prerenderer.cancel()
        // Pictures kept for a project of another structure are found by
        // values that no longer say everything about them (a replaced
        // file, a changed package); an edit of values alone keeps them.
        if playedKey != key { drawingOptions.pictures.removeAll() }
        playedKey = key
        playedUsesRenders = !composed.cachedKeys.isEmpty
        self.frameRate = frameRate
        item.videoComposition = composed.videoComposition(scaledBy: level.scale)
        item.audioMix = composed.audioMix(curves: mixCurves, meter: mixMeter)
        mixMeter.reset()
        scrubAudio.setComposition(composed, curves: mixCurves)
        tapeScrub.setComposition(composed, curves: mixCurves)
    }

    // MARK: The paused frame

    /// The project's values changed while its structure didn't: the
    /// compositor draws every frame with `clips` (see `LiveValues`), playing
    /// or paused, so nothing is built. Paused, the frame on screen is drawn
    /// again from what it was drawn from, in a few milliseconds; where that
    /// can't take values (a render under the playhead, which holds the
    /// values it was made with) the item draws from its clips instead,
    /// which the player shows in a moment. Until then the last picture
    /// stays.
    func showValues(_ clips: [UUID: TimelineClip]) {
        liveValues.clips = clips
        prerenderer.cancel()
        if isPlaying {
            playWithoutRenders()
            return
        }
        if redrawPausedFrame() || playWithoutRenders() { return }
        refreshPlayerFrame()
    }

    /// Draws the paused frame again from what it was drawn from, with the
    /// project's values, at the timeline's full size. False when there is
    /// nothing to draw it from (it wasn't drawn since the player paused
    /// there) or a picture in it can't take the values.
    @discardableResult
    private func redrawPausedFrame() -> Bool {
        guard !isPlaying, player.currentItem != nil, let recorded = capture.recorded else { return false }
        let values = liveValues.clips
        guard FrameRedrawer.canDraw(recorded, values: values) else { return false }
        redrawToken += 1
        return redrawer.redraw(.init(recorded: recorded, values: values, size: recorded.instruction.renderSize, token: redrawToken))
    }

    /// Has the paused player draw its frame again, through its compositor,
    /// which draws it with the project's values and keeps what it drew it
    /// from for the next edit.
    private func refreshPlayerFrame() {
        guard !isPlaying, let item = player.currentItem, let videoComposition = item.videoComposition else { return }
        capture.arm(at: player.currentTime())
        item.videoComposition = videoComposition.mutableCopy() as? AVVideoComposition
        display.wake()
    }

    /// A frame from the current item's output. Playing, it is shown as it
    /// is. Paused while Auto draws smaller, it is drawn again at full size
    /// first, so paused frames are sharp, and the smaller one never shows;
    /// not while scrubbing, which wants every frame at once.
    private func receiveOutputFrame(_ buffer: CVPixelBuffer, at time: CMTime) {
        if isPlaying || isSwapping {
            display.show(buffer, fade: fadesNextFrame)
            fadesNextFrame = false
            return
        }
        if !isSeeking, level != .full, redrawPausedFrame() { return }
        display.show(buffer)
    }

    private func receiveRedrawn(_ buffer: CVPixelBuffer, token: Int) {
        guard token == redrawToken, !isPlaying, !isSwapping else { return }
        prerenderer.cancel()
        display.show(buffer)
    }

    /// Lets go of a frame being drawn again: one of where the player was.
    private func dropRedraw() {
        redrawer.cancel()
        redrawToken += 1
    }

    // MARK: Swapping items

    /// Puts `item`, readied by `prepare`, in the player at `time`, and
    /// returns once the viewer shows its frame, or has waited long enough.
    /// The viewer's picture stays as it was until then: an output only gets
    /// frames from its player's current item, so the item goes in first,
    /// and the picture changes once its frame is there.
    ///
    /// Playing, it plays on from where the timeline has reached by then,
    /// started at an exact host time (`setRate(_:time:atHostTime:)`), so
    /// however long the new item takes to be ready the playhead doesn't
    /// fall behind or jump; its first frame fades in over the last one.
    /// Returns whether its frame was shown.
    @discardableResult
    func swap(to item: AVPlayerItem, at time: CMTime, playing: Bool) async -> Bool {
        dropRedraw()
        prerenderer.cancel()
        if playing {
            isSwapping = true
            defer {
                isSwapping = false
                playStateChanged(player.timeControlStatus != .paused)
            }
            let clock = CMClockGetHostTimeClock()
            let anchorHost = CMClockGetTime(clock)
            let anchor = player.currentTime()
            capture.arm(at: nil)
            player.rate = 0
            player.replaceCurrentItem(with: item)
            display.follow(item)
            await Self.ready(item)
            let lead = CMTime(value: 1, timescale: 10)
            let host = CMClockGetTime(clock)
            let start = CMTimeAdd(CMTimeAdd(anchor, CMTimeSubtract(host, anchorHost)), lead)
            fadesNextFrame = true
            if item.status == .readyToPlay, player.status == .readyToPlay {
                player.setRate(1, time: start, atHostTime: CMTimeAdd(host, lead))
            } else {
                await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
            }
            itemSwaps += 1
            return await display.firstFrame(of: item, within: .seconds(2))
        }
        _ = await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        capture.arm(at: time)
        player.replaceCurrentItem(with: item)
        display.follow(item)
        if CMTimeCompare(item.currentTime(), time) != 0 {
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if await display.firstFrame(of: item, within: .seconds(2)) { return true }
        // A paused player holds back a new item's first picture until its
        // sound is ready, which prerolling usually ends at once; if it still
        // hasn't drawn, it is seeked where it is and prerolled again. A seek
        // to where the item already is can do nothing at all (a timeline
        // switched to was stuck until the playhead moved), so the item is
        // also given its video composition again, which has a paused player
        // draw its frame whatever its time.
        guard player.currentItem === item else { return false }
        NSLog("Viewer: a swapped-in item hadn't drawn after 2 s; redrawing it (%@)", Self.describe(item, in: player, at: time))
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        guard player.currentItem === item, !isPlaying else { return false }
        if player.rate == 0, player.status == .readyToPlay, item.status == .readyToPlay { _ = await player.preroll(atRate: 1) }
        guard player.currentItem === item, !isPlaying else { return false }
        refreshPlayerFrame()
        if await display.firstFrame(of: item, within: .seconds(3)) { return true }
        if player.currentItem === item {
            NSLog("Viewer: a swapped-in item still hadn't drawn after redrawing (%@)", Self.describe(item, in: player, at: time))
        }
        return false
    }

    /// What the player and a stuck item say about themselves, for the log.
    private static func describe(_ item: AVPlayerItem, in player: AVPlayer, at time: CMTime) -> String {
        func status(_ status: AVPlayerItem.Status) -> String {
            switch status {
            case .readyToPlay: "ready"
            case .failed: "failed"
            default: "unknown"
            }
        }
        let control = switch player.timeControlStatus {
        case .paused: "paused"
        case .playing: "playing"
        case .waitingToPlayAtSpecifiedRate: "waiting (\(player.reasonForWaitingToPlay?.rawValue ?? "no reason"))"
        @unknown default: "?"
        }
        return [
            "asked \(time.seconds) s, item at \(item.currentTime().seconds) s of \(item.duration.seconds) s",
            "item \(status(item.status))\(item.error.map { ": \($0.localizedDescription)" } ?? "")",
            "player \(player.status == .readyToPlay ? "ready" : player.status == .failed ? "failed" : "unknown"), \(control)",
            "keeping up \(item.isPlaybackLikelyToKeepUp), buffer empty \(item.isPlaybackBufferEmpty)",
            "outputs \(item.outputs.count), video composition \(item.videoComposition != nil)",
        ].joined(separator: "; ")
    }

    /// Lets the player's item go, for a timeline with nothing to play. The
    /// viewer's picture stays, under what says so.
    func clearItem() {
        dropRedraw()
        prerenderer.cancel()
        capture.arm(at: nil)
        if player.rate != 0 { player.pause() }
        player.replaceCurrentItem(with: nil)
        composed = nil
        playedKey = nil
        playedUsesRenders = false
    }

    /// Waits until `item` is ready to play or has failed, for at most two
    /// seconds.
    private static func ready(_ item: AVPlayerItem) async {
        for _ in 0..<200 where item.status == .unknown {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func playStateChanged(_ playing: Bool) {
        guard !isSwapping, playing != isPlaying else { return }
        // The periodic ticks only come every 30th of a second; the parked
        // playhead should land exactly where playing stopped. Not while a
        // seek is in flight: its target is already set, and the player
        // hasn't reached it yet.
        if !playing, !isSeeking, !playerIsSkimmed { currentTime = player.currentTime() }
        isPlaying = playing
        display.isPlaying = playing
        if playing {
            prerenderer.cancel()
            dropRedraw()
            capture.arm(at: nil)
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
        if !playing {
            // The frame it stopped on was drawn while playing, which keeps
            // nothing; drawn smaller, it is drawn again at full size.
            capture.arm(at: player.currentTime())
            if level != .full { refreshPlayerFrame() }
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
            item.videoComposition = composed.videoComposition(scaledBy: wanted.scale, withoutRenders: !playedUsesRenders)
        }
        // Paused, the player draws the frame again at the new size, which
        // is drawn at full size if it is smaller.
        if !isPlaying { capture.arm(at: player.currentTime()) }
        display.wake()
        prerollIfPaused()
    }

    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeek: CMTime?

    /// Scrub-friendly seek: only one seek is ever in flight, and a newer
    /// target replaces any that was queued behind it, so dragging the
    /// playhead doesn't pile up zero-tolerance seeks.
    ///
    /// The playhead is the master: moving it pauses playback, and what
    /// was playing doesn't start again from where it lands.
    func seek(to time: CMTime) {
        if isTapeScrubbing { stopTape() }
        if isPlaying || player.rate != 0 { player.pause() }
        tapeScrub.cue(time.seconds)
        move(to: time)
    }

    /// Another timeline is shown, from `time`: playing and tape scrubbing
    /// stop, and the playhead goes there. Nothing is seeked: the timeline's
    /// item is swapped in at `time` (`ViewerPipeline`), and a skim or seek
    /// of the one before is let go, which would otherwise take the new
    /// item to a time of the old timeline.
    func showTimeline(from time: CMTime) {
        if isTapeScrubbing { stopTape() }
        if isPlaying || player.rate != 0 { player.pause() }
        pendingSeek = nil
        skimTime = nil
        playerIsSkimmed = false
        tapeScrub.cue(time.seconds)
        currentTime = time
    }

    /// Moves the playhead and seeks the player, playing a grain of the
    /// mix there unless the tape scrubber is playing it already.
    private func move(to time: CMTime, playsGrain: Bool = true) {
        if playsGrain { playGrain(at: time) }
        // Moving the playhead takes the viewer back from a skim.
        skimTime = nil
        currentTime = time
        show(time)
    }

    /// Shows the timeline at `time`, where the pointer is, without moving
    /// the playhead, with a grain of the mix there. Nothing while playing
    /// or tape scrubbing, which the viewer follows instead.
    func skim(to time: CMTime) {
        guard !isPlaying, !isTapeScrubbing, player.currentItem != nil, time != skimTime else { return }
        skimTime = time
        playerIsSkimmed = true
        playGrain(at: time)
        show(time)
    }

    /// Ends skimming: the viewer goes back to the playhead.
    func endSkim() {
        guard skimTime != nil else { return }
        skimTime = nil
        show(currentTime)
    }

    /// Plays the grain of the mix at `time`, from the start of its frame,
    /// so every move within one frame asks for the same grain, which plays
    /// once. Not while playing, or with Scrub Audio off.
    private func playGrain(at time: CMTime) {
        guard !isPlaying, UserDefaults.standard.object(forKey: Preferences.scrubAudio) as? Bool ?? true else { return }
        let seconds = frameRate > 0 ? (time.seconds * frameRate + 1e-6).rounded(.down) / frameRate : time.seconds
        scrubAudio.play(at: seconds, deviceUID: outputUID)
    }

    /// Seeks the player to `time`, after any seek under way.
    private func show(_ time: CMTime) {
        pendingSeek = time
        prerenderer.cancel()
        restingPreroll?.cancel()
        restingPreroll = nil
        player.cancelPendingPrerolls()
        dropRedraw()
        capture.arm(at: time)
        display.wake()
        guard !isSeeking else { return }
        isSeeking = true
        Task { await drainSeeks() }
    }

    /// Whether the player was sent to a skim and hasn't yet come back to
    /// the playhead: until then its time isn't the playhead's.
    @ObservationIgnored private var playerIsSkimmed = false

    /// How many times the player was prerolled, for tests.
    @ObservationIgnored private(set) var prerolls = 0
    /// The preroll waiting for the playhead to rest after a seek.
    @ObservationIgnored private var restingPreroll: Task<Void, Never>?
    /// How long the playhead must rest after a seek before the player is
    /// prerolled there. A preroll decodes ahead of the playhead, and a
    /// drag's next seek, about 16 ms later, waited behind it: on a timeline
    /// nesting another over long-GOP footage a step took 130 ms instead of
    /// 10, and the viewer showed a few frames a second.
    static let prerollRest: Duration = .milliseconds(250)

    private func drainSeeks() async {
        while let target = pendingSeek {
            pendingSeek = nil
            _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        isSeeking = false
        if skimTime == nil { playerIsSkimmed = false }
        // Settled: the frame is drawn at full size if it was drawn smaller.
        if !isPlaying, level != .full { redrawPausedFrame() }
        restingPreroll?.cancel()
        restingPreroll = Task { [weak self] in
            try? await Task.sleep(for: Self.prerollRest)
            guard !Task.isCancelled, let self else { return }
            self.restingPreroll = nil
            self.prerollIfPaused()
        }
    }

    /// The item was swapped while playing and has seeked and resumed.
    func noteItemSwappedWhilePlaying() { itemSwaps += 1 }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            return
        }
        // Play starts from the frame skimmed to, as the viewer shows it.
        if let skimTime { move(to: skimTime, playsGrain: false) }
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
