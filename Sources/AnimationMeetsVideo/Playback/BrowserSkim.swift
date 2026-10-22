import AVFoundation
import CoreMedia
import Observation

/// Skimming a clip in the browser: the viewer shows the clip's frame under
/// the pointer, or at the keyboard's skim position, with a grain of its
/// sound at each frame (`ScrubAudio`, unless Skim Audio is off), and Space
/// plays the clip from there. It plays from the clip's file with a player of its own,
/// shown over the viewer's picture, so the timeline's composition is never
/// rebuilt and nothing on the timeline changes. See docs/browser.md,
/// "Skimming".
@MainActor
@Observable
final class BrowserSkim {
    /// What is skimmed: a stretch of an asset's original time, the whole
    /// asset or one of its scenes.
    struct Target: Equatable {
        /// The browser item it is, so its strip can draw the skim line.
        var item: AnyHashable
        var clip: MediaClip
        var start: CMTime
        var duration: CMTime

        var seconds: Double { duration.seconds }
    }

    private(set) var target: Target?
    /// Where in the target the viewer is, in seconds into it.
    private(set) var seconds: Double = 0
    /// Playing the clip (Space), with its sound; skimming plays grains.
    private(set) var isPlaying = false

    var isActive: Bool { target != nil }

    /// The time shown, in the asset's original time.
    var sourceTime: CMTime {
        CMTimeAdd(target?.start ?? .zero, CMTime(seconds: seconds, preferredTimescale: 600))
    }

    @ObservationIgnored let player = AVPlayer()
    /// Whether this skimmer is heard, skimming and playing, whatever the
    /// browser's Skimming settings say; nil follows them. The scene
    /// splitter has a sound switch of its own.
    @ObservationIgnored var soundOverride: Bool?
    /// Grains of the skimmed file's sound, read from the file itself.
    @ObservationIgnored let scrubAudio = ScrubAudio()
    @ObservationIgnored private var soundLoad: Task<Void, Never>?
    @ObservationIgnored private var itemURL: URL?
    @ObservationIgnored private var pendingSeek: CMTime?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    /// Opens the clip's file, through its reference movie for a Matroska
    /// file. The one place skimming opens media.
    nonisolated static func asset(at url: URL) -> AVURLAsset {
        MediaFile.asset(at: url)
    }

    /// Whether a clip can be skimmed: one with time to move through.
    static func canSkim(_ clip: MediaClip) -> Bool {
        clip.kind != .image && clip.url != nil && clip.duration > .zero
    }

    /// Shows `target` at `seconds` into it, silently, stopping play.
    func skim(_ target: Target, at seconds: Double) {
        guard Self.canSkim(target.clip), let url = target.clip.url else { return }
        if url != itemURL {
            itemURL = url
            let asset = Self.asset(at: url)
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            loadSound(of: asset, url: url)
        }
        if target != self.target {
            self.target = target
            player.currentItem?.forwardPlaybackEndTime = fileTime(target.seconds)
        }
        if isPlaying { stopPlaying() }
        self.seconds = Self.clamped(seconds, to: target)
        chase(fileTime(self.seconds))
        playGrain()
    }

    /// Moves the skim position `frames` frames, a frame being the clip's own
    /// (or a 30th of a second for sound).
    func step(frames: Int) {
        guard let target else { return }
        let rate = target.clip.frameRate > 0 ? target.clip.frameRate : 30
        let frame = ((seconds * rate).rounded() + Double(frames)) / rate
        skim(target, at: frame)
    }

    /// Plays the clip from the skim position, with sound, to its end; or
    /// stops it, staying on the frame reached.
    func togglePlay() {
        guard target != nil else { return }
        if isPlaying {
            stopPlaying()
            return
        }
        // At the end, play starts again from the start.
        if let target, seconds >= target.seconds - 1e-3 { skim(target, at: 0) }
        isPlaying = true
        scrubAudio.stop()
        player.isMuted = soundOverride == false
        player.play()
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.followPlay(to: time) }
        }
        // The player stops at the clip's end without a last tick of the
        // time observer, so its end is watched for.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let target = self.target else { return }
                self.stopPlaying()
                self.seconds = target.seconds
            }
        }
    }

    /// Ends skimming: the viewer shows the timeline again.
    func end() {
        stopPlaying()
        scrubAudio.stop()
        soundLoad?.cancel()
        soundLoad = nil
        scrubAudio.setFile(nil, tracks: [])
        target = nil
        seconds = 0
        pendingSeek = nil
        itemURL = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Playing

    private func followPlay(to time: CMTime) {
        guard isPlaying, let target else { return }
        seconds = Self.clamped(time.seconds - fileTime(0).seconds, to: target)
        if player.timeControlStatus == .paused { stopPlaying() }
    }

    private func stopPlaying() {
        player.pause()
        player.isMuted = true
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        isPlaying = false
    }

    // MARK: Sound

    /// Hands the file's sound tracks to the grains once they are loaded;
    /// until then, and for a file with none, skimming is silent.
    private func loadSound(of asset: AVURLAsset, url: URL) {
        scrubAudio.setFile(nil, tracks: [])
        soundLoad?.cancel()
        soundLoad = Task { [weak self] in
            let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            guard let self, !Task.isCancelled, self.itemURL == url, !tracks.isEmpty else { return }
            self.scrubAudio.setFile(asset, tracks: tracks)
        }
    }

    /// Plays a grain of the clip's sound from the start of the frame
    /// skimmed to, so each frame is heard once however many moves of the
    /// pointer it takes to cross it. Skim Audio is set under Skimming, so
    /// with skimming off a frame clicked or stepped to is silent too.
    private func playGrain() {
        let defaults = UserDefaults.standard
        guard let target, target.clip.hasAudio || target.clip.kind == .audio,
              soundOverride ?? (defaults.object(forKey: Preferences.browserSkimming) as? Bool ?? true
                  && defaults.object(forKey: Preferences.browserSkimAudio) as? Bool ?? true)
        else { return }
        let rate = target.clip.frameRate > 0 ? target.clip.frameRate : 30
        let seconds = fileTime(self.seconds).seconds
        scrubAudio.play(at: (seconds * rate + 1e-6).rounded(.down) / rate, deviceUID: AudioDevices.playbackUID)
    }

    // MARK: Seeking

    /// Seeks frame-exactly, one seek at a time: moves that arrive while one
    /// is under way wait, and only the newest of them is sought next, so the
    /// picture keeps up with the pointer instead of falling behind it.
    private func chase(_ time: CMTime) {
        player.isMuted = true
        pendingSeek = time
        if !isSeeking { seekNext() }
    }

    private func seekNext() {
        guard let time = pendingSeek else {
            isSeeking = false
            return
        }
        pendingSeek = nil
        isSeeking = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.seekNext() }
        }
    }

    // MARK: Times

    /// Where `seconds` into the target is in the file.
    private func fileTime(_ seconds: Double) -> CMTime {
        guard let target else { return .zero }
        let source = CMTimeAdd(target.start, CMTime(seconds: seconds, preferredTimescale: 600))
        return target.clip.fileTime(forSourceTime: source)
    }

    static func clamped(_ seconds: Double, to target: Target) -> Double {
        min(max(seconds, 0), max(target.seconds, 0))
    }
}
