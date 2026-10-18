import AVFoundation
import CoreMedia
import Foundation

/// Plays a short grain of the mix wherever the playhead is moved while
/// paused, so a cut or a beat can be found by ear as well as by eye. See
/// docs/audio.md, "Scrubbing".
///
/// The mix around the playhead is read out through the composition's audio
/// mix, as playback hears it, a few seconds at a time, and kept; grains come
/// from that. Everything (reading, the engine, scheduling) happens on one
/// serial queue.
///
/// A grain is never cut off: that is what made scrubbing crackle, a hard
/// stop mid-waveform for every move of a drag. Grains are paced instead
/// (`GrainPacer`): while the playhead keeps moving, each starts `hop` after
/// the last, from wherever the playhead is by then, on the other of two
/// players, so it fades in while the last one fades out. The fades are
/// raised cosines, which sum to a steady level across the overlap.
final class ScrubAudio: @unchecked Sendable {
    /// How much of the mix is read at once: a little before the playhead
    /// and more after, since scrubbing mostly moves forward.
    static let before = 1.0
    static let after = 3.0
    /// One grain: long enough to tell what it is, short enough to follow a
    /// drag.
    static let grain = 0.08
    /// Each end of a grain fades over this, so it doesn't click; it is
    /// also how much one grain overlaps the next.
    static let fade = 0.01
    /// How far apart grains start while the playhead keeps moving.
    static let hop = grain - fade
    /// How far ahead of its start a grain is handed to its player.
    static let lead = 0.015
    static let sampleRate = 48_000.0

    private let queue = DispatchQueue(label: "AnimationMeetsVideo.scrub-audio", qos: .userInitiated)

    // Touched only on `queue`.
    private var composed: ComposedTimeline?
    private var curves: MixCurves?
    private var cache: (start: Double, left: [Float], right: [Float])?
    private var engine: AVAudioEngine?
    /// Two players, taken in turn, so a grain fades in while the one before
    /// it fades out on the other.
    private var nodes: [AVAudioPlayerNode] = []
    private var nextNode = 0
    private var deviceUID: String?
    private var pacer = GrainPacer(hop: hop, lead: lead)

    /// Takes up a new composition to read from, forgetting what was read
    /// of the old one.
    func setComposition(_ composed: ComposedTimeline?, curves: MixCurves) {
        let handed = HandedOver(value: composed)
        queue.async {
            self.composed = handed.value
            self.curves = curves
            self.cache = nil
        }
    }

    /// Forgets what was read, after an edit changed what the mix sounds
    /// like.
    func forget() {
        queue.async { self.cache = nil }
    }

    /// Plays the grain at `seconds` of the timeline, out of the device
    /// with `deviceUID` (nil for the system's default).
    func play(at seconds: Double, deviceUID: String?) {
        guard seconds.isFinite else { return }
        queue.async {
            switch self.pacer.request(max(0, seconds), now: Self.now()) {
            case .play(let seconds):
                self.play(seconds, at: nil, deviceUID: deviceUID)
            case .wait(let until):
                self.queue.asyncAfter(deadline: .now() + max(0, until - Self.now())) {
                    guard let next = self.pacer.fire(now: Self.now()) else { return }
                    self.play(next.seconds, at: next.start, deviceUID: deviceUID)
                }
            case .none:
                break
            }
        }
    }

    /// Stops what is playing and lets the engine go.
    func stop() {
        queue.async {
            self.pacer.reset()
            for node in self.nodes { node.stop() }
            self.engine?.stop()
            self.engine = nil
            self.nodes = []
        }
    }

    /// The grain `play` would play at `seconds`, without playing it.
    func samples(at seconds: Double) async -> (left: [Float], right: [Float])? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.grain(at: max(0, seconds))) }
        }
    }

    // MARK: On the queue

    /// The grain's samples, left and right, reading the mix around it first
    /// if it isn't kept already. Nil when there is no sound there.
    private func grain(at seconds: Double) -> (left: [Float], right: [Float])? {
        let frames = Int(Self.grain * Self.sampleRate)
        if cache.map({ seconds < $0.start || seconds + Self.grain > $0.start + Double($0.left.count) / Self.sampleRate }) ?? true {
            cache = read(from: max(0, seconds - Self.before))
        }
        guard let cache else { return nil }
        let first = Int(((seconds - cache.start) * Self.sampleRate).rounded())
        guard first >= 0, first < cache.left.count else { return nil }
        let end = min(cache.left.count, first + frames)
        var left = Array(cache.left[first..<end]), right = Array(cache.right[first..<end])
        let fade = min(left.count / 2, Int(Self.fade * Self.sampleRate))
        for index in 0..<fade {
            let gain = Self.fadeIn(Float(index) / Float(fade))
            left[index] *= gain
            right[index] *= gain
            left[left.count - 1 - index] *= gain
            right[right.count - 1 - index] *= gain
        }
        return (left, right)
    }

    /// A raised cosine from 0 to 1 over 0...1: it starts and ends flat, so
    /// it doesn't click, and with its mirror image it sums to 1.
    static func fadeIn(_ x: Float) -> Float {
        0.5 - 0.5 * cos(.pi * min(max(x, 0), 1))
    }

    /// Now on the host clock, in seconds.
    private static func now() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    /// Plays the grain at `seconds`, starting at `start` on the host clock
    /// in seconds, or at once.
    private func play(_ seconds: Double, at start: Double?, deviceUID: String?) {
        guard let grain = grain(at: seconds) else { return }
        schedule(grain, at: start, deviceUID: deviceUID)
    }

    /// Reads the mix from `start` for `before + after` seconds.
    private func read(from start: Double) -> (start: Double, left: [Float], right: [Float])? {
        MixReading.read(composed, curves: curves, from: start, duration: Self.before + Self.after, sampleRate: Self.sampleRate)
    }

    private func schedule(_ grain: (left: [Float], right: [Float]), at start: Double?, deviceUID: String?) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(grain.left.count)),
              startEngine(deviceUID: deviceUID, format: format)
        else { return }
        buffer.frameLength = AVAudioFrameCount(grain.left.count)
        buffer.floatChannelData![0].update(from: grain.left, count: grain.left.count)
        buffer.floatChannelData![1].update(from: grain.right, count: grain.right.count)
        // The other player from last time, whose grain ended a hop ago:
        // nothing is cut off. A start already past plays at once.
        let node = nodes[nextNode]
        nextNode = (nextNode + 1) % nodes.count
        let when = start.flatMap { $0 > Self.now() ? AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: $0)) : nil }
        node.scheduleBuffer(buffer, at: when)
        node.play()
    }

    /// Starts the engine on `deviceUID`'s device, making it again when the
    /// device changed. False when it can't start.
    private func startEngine(deviceUID: String?, format: AVAudioFormat) -> Bool {
        if let engine, engine.isRunning, !nodes.isEmpty, self.deviceUID == deviceUID { return true }
        engine?.stop()
        let engine = AVAudioEngine()
        let nodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]
        for node in nodes { engine.attach(node) }
        if let device = deviceUID.flatMap({ AudioDevices.device(uid: $0)?.id }), let unit = engine.outputNode.audioUnit {
            var device = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        for node in nodes { engine.connect(node, to: engine.mainMixerNode, format: format) }
        engine.prepare()
        guard (try? engine.start()) != nil else { return false }
        self.engine = engine
        self.nodes = nodes
        nextNode = 0
        self.deviceUID = deviceUID
        return true
    }
}

/// When scrub grains start. A move of the playhead with nothing playing
/// starts one at once; moves while one plays wait for the next start, a
/// hop after the last, and the newest of them plays from where the
/// playhead is then. A move to where the newest grain already plays (or
/// waits to) asks for nothing: a drag crosses many pixels in a frame, and
/// a frame is heard once. Times are seconds on the host clock.
struct GrainPacer: Equatable {
    enum Action: Equatable {
        /// Play from these seconds of the timeline now.
        case play(Double)
        /// Come back at this time (`fire`), a lead before the next start.
        case wait(until: Double)
        /// A wait is already set; the newest request will play then.
        case none
    }

    let hop: Double
    let lead: Double
    private var lastStart: Double?
    private var pending: Double?
    private var waiting = false
    /// Where the last grain played from, in the timeline.
    private var lastPlayed: Double?

    init(hop: Double, lead: Double) {
        self.hop = hop
        self.lead = lead
    }

    mutating func request(_ seconds: Double, now: Double) -> Action {
        if seconds == (pending ?? lastPlayed) { return .none }
        if waiting {
            pending = seconds
            return .none
        }
        if let lastStart, now < lastStart + hop {
            pending = seconds
            waiting = true
            return .wait(until: lastStart + hop - lead)
        }
        lastStart = now
        lastPlayed = seconds
        return .play(seconds)
    }

    /// At the time a wait asked for: what to play, and when it starts,
    /// exactly a hop after the last. Nil when it was reset meanwhile.
    mutating func fire(now: Double) -> (seconds: Double, start: Double)? {
        waiting = false
        guard let seconds = pending, let lastStart else { return nil }
        pending = nil
        let start = max(now, lastStart + hop)
        self.lastStart = start
        lastPlayed = seconds
        return (seconds, start)
    }

    mutating func reset() {
        lastStart = nil
        pending = nil
        waiting = false
        lastPlayed = nil
    }
}
