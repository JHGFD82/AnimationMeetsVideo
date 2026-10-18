import AVFoundation
import CoreMedia
import Foundation

/// Plays a short tone on each beat marker while the player plays, so the
/// markers can be checked by ear against the music. A downbeat's tone is an
/// octave higher, so the measures can be heard too.
///
/// Blips are scheduled ahead on an `AVAudioPlayerNode` at host times taken
/// from the player item's timebase, rather than fired from a time observer,
/// so they land on the beat instead of whenever the main thread gets to
/// them. Anything that moves the timebase (play, pause, seek, a rebuilt
/// item) throws away what was scheduled and starts again from now.
@MainActor
final class BeatClickPlayer {
    /// One beat to click on: where it is in the player item's time, and
    /// whether it starts a measure.
    struct Tick: Equatable {
        var time: CMTime
        var isDownbeat = false
    }

    /// The beats to click on, sorted by time.
    var beats: [Tick] = [] {
        didSet { if beats != oldValue { restart() } }
    }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { startEngine() } else { stopEngine() }
            restart()
        }
    }

    /// The tone's pitch, in hertz.
    var frequency: Double = 1000 {
        didSet {
            guard frequency != oldValue else { return }
            blip = nil
            downbeatBlip = nil
            restart()
        }
    }

    /// How loud the tone is, from silent (0) to full (1).
    var volume: Float = 0.8 {
        didSet {
            clickNode.volume = volume
            previewNode.volume = volume
        }
    }

    /// The device the tick plays out of, by its UID, or nil for the
    /// system's default. Moving to it happens off the main thread: a
    /// device can take seconds to wake (a display's speakers, say).
    var outputDeviceUID: String? {
        didSet {
            guard outputDeviceUID != oldValue else { return }
            switchDevice()
        }
    }

    /// While the engine moves to another device on `engineQueue`, nothing
    /// on the main thread touches it.
    private var isSwitching = false
    /// Counts switches, so only the newest one's ending is taken up.
    private var switchCount = 0
    private let engineQueue = DispatchQueue(label: "AnimationMeetsVideo.beat-clicks", qos: .userInitiated)

    /// The downbeat is an octave up, so this stops at 2000 Hz for the
    /// downbeat's 4000.
    nonisolated static let frequencyRange: ClosedRange<Double> = 200...2000

    private let player: AVPlayer
    private let engine = AVAudioEngine()
    private let clickNode = AVAudioPlayerNode()
    private let previewNode = AVAudioPlayerNode()
    private var blip: AVAudioPCMBuffer?
    private var downbeatBlip: AVAudioPCMBuffer?
    /// Item time up to which beats are scheduled, or nil when none are.
    private var scheduledThrough: CMTime?
    private var timer: Timer?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []

    /// How far ahead beats are scheduled, and how often more are added.
    private let lookahead = 1.0
    private let refreshInterval = 0.25

    init(player: AVPlayer) {
        self.player = player
        engine.attach(clickNode)
        engine.attach(previewNode)
        clickNode.volume = volume
        previewNode.volume = volume
        connectNodes()

        let restartOnMain: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.restart() }
        }
        observations = [
            player.observe(\.timeControlStatus) { _, _ in restartOnMain() },
            player.observe(\.currentItem) { _, _ in restartOnMain() },
        ]
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main) { _ in
                restartOnMain()
            },
            center.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main) { [weak player] note in
                guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
                restartOnMain()
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                // A changed output device stops the engine and may change
                // its sample rate.
                Task { @MainActor in self?.handleConfigurationChange() }
            },
        ]
    }

    /// Plays one blip now, at the current pitch and volume: a downbeat's
    /// when asked for.
    func preview(downbeat: Bool = false) {
        guard !isSwitching else { return }
        startEngine()
        guard engine.isRunning, let blip = currentBlip(downbeat: downbeat) else { return }
        previewNode.scheduleBuffer(blip, at: nil, options: .interrupts)
        previewNode.play()
    }

    // MARK: - Scheduling

    private func restart() {
        clickNode.stop()
        scheduledThrough = nil
        timer?.invalidate()
        timer = nil
        guard isEnabled, !beats.isEmpty, !isSwitching, engine.isRunning,
              let timebase = player.currentItem?.timebase, CMTimebaseGetRate(timebase) > 0
        else { return }
        clickNode.play()
        scheduleAhead()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAhead() }
        }
    }

    /// Schedules the beats between where scheduling left off and a little
    /// past now.
    private func scheduleAhead() {
        guard let timebase = player.currentItem?.timebase, CMTimebaseGetRate(timebase) > 0,
              let blip = currentBlip(downbeat: false), let downbeat = currentBlip(downbeat: true)
        else { return }
        let now = CMTimebaseGetTime(timebase)
        let from = scheduledThrough.map { CMTimeMaximum($0, now) } ?? now
        let to = CMTimeAdd(now, CMTime(seconds: lookahead, preferredTimescale: 600))
        guard CMTimeCompare(from, to) < 0 else { return }
        // AVPlayer delays its picture to match the audio device's latency;
        // the blips are scheduled for when they are heard, the same way.
        let latency = engine.outputNode.presentationLatency
        let hostClock = CMClockGetHostTimeClock()
        let start = beats.lowerBound(of: from.seconds) { $0.time.seconds }
        for beat in beats[start...] {
            guard CMTimeCompare(beat.time, to) < 0 else { break }
            let hostTime = CMSyncConvertTime(beat.time, from: timebase, to: hostClock)
            let ticks = AVAudioTime.hostTime(forSeconds: max(0, hostTime.seconds - latency))
            clickNode.scheduleBuffer(beat.isDownbeat ? downbeat : blip, at: AVAudioTime(hostTime: ticks))
        }
        scheduledThrough = to
    }

    // MARK: - Engine

    private func connectNodes() {
        Self.connect(clickNode, previewNode, in: engine)
        blip = nil
        downbeatBlip = nil
    }

    /// Connects the nodes at the output's sample rate.
    private nonisolated static func connect(_ click: AVAudioPlayerNode, _ preview: AVAudioPlayerNode, in engine: AVAudioEngine) {
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return
        }
        engine.connect(click, to: engine.mainMixerNode, format: format)
        engine.connect(preview, to: engine.mainMixerNode, format: format)
    }

    /// Moves the engine to `outputDeviceUID`'s device, or the system's
    /// default, on `engineQueue`, and takes up scheduling again once it is
    /// there.
    private func switchDevice() {
        let device = outputDeviceUID.flatMap { AudioDevices.device(uid: $0)?.id } ?? Self.defaultOutputDevice()
        let starts = isEnabled
        clickNode.stop()
        previewNode.stop()
        isSwitching = true
        switchCount += 1
        let count = switchCount
        // Handed to the queue whole; the main thread leaves them alone
        // while `isSwitching`.
        let parts = HandedOver(value: (engine, clickNode, previewNode))
        engineQueue.async {
            let (engine, click, preview) = parts.value
            engine.stop()
            if device != 0, let unit = engine.outputNode.audioUnit {
                var device = device
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            Self.connect(click, preview, in: engine)
            if starts {
                engine.prepare()
                try? engine.start()
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, count == self.switchCount else { return }
                    self.isSwitching = false
                    self.blip = nil
                    self.downbeatBlip = nil
                    // Switched on or off while it moved.
                    if self.isEnabled { self.startEngine() } else { self.stopEngine() }
                    self.restart()
                }
            }
        }
    }

    private nonisolated static func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private func startEngine() {
        guard !isSwitching, !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    private func stopEngine() {
        guard !isSwitching else { return }
        clickNode.stop()
        previewNode.stop()
        engine.stop()
    }

    private func handleConfigurationChange() {
        // A switch changes the configuration itself, and sets it up anew
        // when it is done.
        guard !isSwitching else { return }
        engine.stop()
        connectNodes()
        if isEnabled { startEngine() }
        restart()
    }

    private func currentBlip(downbeat: Bool) -> AVAudioPCMBuffer? {
        if let made = downbeat ? downbeatBlip : blip { return made }
        let format = clickNode.outputFormat(forBus: 0)
        let made = Self.makeBlip(frequency: downbeat ? 2 * frequency : frequency, format: format)
        if downbeat { downbeatBlip = made } else { blip = made }
        return made
    }

    /// A 50 ms sine tone with a quick fade in and an exponential decay, so
    /// it reads as a click with a pitch rather than a beep.
    nonisolated static func makeBlip(frequency: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * 0.05)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = frameCount
        let attack = 0.002
        let decay = 0.012
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let envelope = min(1, t / attack) * exp(-t / decay)
            let sample = Float(0.5 * envelope * sin(2 * .pi * frequency * t))
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }
        return buffer
    }
}
