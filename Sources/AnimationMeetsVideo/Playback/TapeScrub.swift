import AVFoundation
import Foundation
import Synchronization

/// Plays the mix the way tape sounds rocked by hand across a playback
/// head: without a break, at whatever speed and direction the Tape
/// Scrubber's dial asks for, its pitch going up and down with the speed.
/// See docs/audio.md, "Tape scrubbing".
///
/// The mix is read in pieces (`TapePiece`) around where the tape is, more
/// of them ahead the way it is going, on a queue of its own. The engine's
/// render thread plays from whatever pieces are there (`TapeTransport`),
/// so a turn of the dial is heard within one output buffer, about 10 ms;
/// a piece not read yet is silence. The engine runs while the scrubber's
/// window is open, so grabbing the dial doesn't wait for a device.
final class TapeScrub: @unchecked Sendable {
    static let sampleRate = 48_000.0
    /// How much of the mix one piece holds.
    static let pieceSeconds = 2.0
    /// Read before each piece and thrown away, so effects that need sound
    /// before they say anything (voice isolation) are running by its start.
    static let preroll = 0.25
    /// Pieces kept ready ahead of the one playing, and behind it.
    static let ahead = 2
    static let behind = 1
    /// Pieces further than this from the one playing are let go.
    static let kept = 4
    /// The fastest the tape goes, either way.
    static let maxRate = 8.0
    /// How long the speed takes to follow the dial (a time constant):
    /// too short to feel, long enough that a jump in speed doesn't click.
    static let glide = 0.015
    /// Below this speed the sound fades away, as tape's does, rather than
    /// holding one sample, which would click on starting and stopping.
    static let quiet = 0.03

    private let queue = DispatchQueue(label: "AnimationMeetsVideo.tape-scrub", qos: .userInitiated)
    /// What the render thread and everyone else both touch.
    private let shared = TapeShared()
    private let head = TapeHead()

    // Touched only on `queue`.
    private var composed: ComposedTimeline?
    private var curves: MixCurves?
    private var engine: AVAudioEngine?
    private var deviceUID: String?
    private var timer: DispatchSourceTimer?

    /// The speed for the dial dragged `points` from where it was grabbed,
    /// negative to the left: slow at first, faster the further it goes,
    /// up to `maxRate`. A point or two either way is still.
    static func rate(forDrag points: Double) -> Double {
        let x = max(0, abs(points) - 2) / 150
        let speed = min(maxRate, 0.25 * x + 0.75 * x * x)
        return points < 0 ? -speed : speed
    }

    /// Where the tape is, in seconds of the timeline.
    var position: Double { shared.position }

    /// Whether the tape has come to rest with nothing asking it to move.
    var isStopped: Bool { shared.target == 0 && shared.rate == 0 }

    /// Takes up a new composition to read from, forgetting what was read
    /// of the old one.
    func setComposition(_ composed: ComposedTimeline?, curves: MixCurves) {
        let handed = HandedOver(value: composed)
        shared.end = composed.map { max(0, $0.composition.duration.seconds) } ?? 0
        queue.async {
            self.composed = handed.value
            self.curves = curves
            self.shared.clearPieces()
            self.keepLoaded()
        }
    }

    /// Forgets what was read, after an edit changed what the mix sounds
    /// like.
    func forget() {
        queue.async {
            self.shared.clearPieces()
            self.keepLoaded()
        }
    }

    /// Puts the tape at `seconds`, at rest, and reads the mix there so
    /// grabbing the dial is heard at once.
    func cue(_ seconds: Double) {
        guard seconds.isFinite else { return }
        shared.cue(max(0, seconds))
        queue.async { self.keepLoaded() }
    }

    /// Asks the tape to move at `rate`: times normal speed, backwards when
    /// negative, still at 0. It glides there rather than jumping.
    func setRate(_ rate: Double) {
        shared.target = rate.isFinite ? min(Self.maxRate, max(-Self.maxRate, rate)) : 0
    }

    /// Starts the engine out of the device with `deviceUID` (nil for the
    /// system's default), or moves it there.
    func open(deviceUID: String?) {
        queue.async { self.start(deviceUID: deviceUID) }
    }

    /// Moves the engine to another device, if it is running.
    func route(deviceUID: String?) {
        queue.async {
            guard self.engine != nil, self.deviceUID != deviceUID else { return }
            self.start(deviceUID: deviceUID)
        }
    }

    /// Stops the tape and the engine, and lets go of what was read.
    func close() {
        shared.target = 0
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.engine?.stop()
            self.engine = nil
            self.shared.clearPieces()
        }
    }

    // MARK: On the queue

    private func start(deviceUID: String?) {
        engine?.stop()
        engine = nil
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) else { return }
        let engine = AVAudioEngine()
        let node = AVAudioSourceNode(format: format) { [shared, head] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            head.render(shared: shared, frames: Int(frameCount), left: left, right: right)
            return noErr
        }
        engine.attach(node)
        if let device = deviceUID.flatMap({ AudioDevices.device(uid: $0)?.id }), let unit = engine.outputNode.audioUnit {
            var device = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        guard (try? engine.start()) != nil else { return }
        self.engine = engine
        self.deviceUID = deviceUID
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(30))
            timer.setEventHandler { [weak self] in self?.keepLoaded() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Reads the next piece missing around the tape, the one playing
    /// first, then ahead the way it moves, then behind, and lets go of
    /// those far away. One piece at a time, coming straight back for the
    /// next, so a cue meanwhile is seen before reading on.
    private func keepLoaded() {
        guard engine != nil, composed != nil else { return }
        let backwards = shared.rate < 0 || (shared.rate == 0 && shared.target < 0)
        let loaded = shared.pieceIndexes
        let wanted = Self.wanted(at: shared.position, backwards: backwards, end: shared.end)
        if let index = wanted.first(where: { !loaded.contains($0) }) {
            shared.store(Self.read(index, of: composed, curves: curves), at: index)
            queue.async { self.keepLoaded() }
            return
        }
        let current = Int((shared.position / Self.pieceSeconds).rounded(.down))
        shared.dropPieces { abs($0 - current) > Self.kept }
    }

    /// The pieces to have ready with the tape at `seconds`, most needed
    /// first: the one it is in, then `ahead` the way it goes, then
    /// `behind`; only those within a timeline ending at `end`.
    static func wanted(at seconds: Double, backwards: Bool, end: Double) -> [Int] {
        let current = Int((seconds / pieceSeconds).rounded(.down))
        let way = backwards ? -1 : 1
        let last = Int((end / pieceSeconds).rounded(.up)) - 1
        let all = [current] + (1...ahead).map { current + $0 * way } + (1...behind).map { current - $0 * way }
        return all.filter { $0 >= 0 && $0 <= last }
    }

    /// Reads piece `index` of the mix, starting the preroll before it. A
    /// stretch with no sound is a piece of silence, so it isn't read over
    /// and over. Blocks while it reads.
    static func read(_ index: Int, of composed: ComposedTimeline?, curves: MixCurves?) -> TapePiece {
        let frames = Int(pieceSeconds * sampleRate)
        let start = Double(index) * pieceSeconds
        let from = max(0, start - preroll)
        var left = [Float](repeating: 0, count: frames), right = left
        if let mix = MixReading.read(composed, curves: curves, from: from, duration: start + pieceSeconds - from, sampleRate: sampleRate) {
            let offset = Int(((mix.start - start) * sampleRate).rounded())
            for frame in max(0, -offset)..<min(mix.left.count, frames - offset) {
                left[frame + offset] = mix.left[frame]
                right[frame + offset] = mix.right[frame]
            }
        }
        return TapePiece(left: left, right: right)
    }
}

/// One piece of the mix: `TapeScrub.pieceSeconds` of it, left and right,
/// starting at its index times that.
final class TapePiece: Sendable {
    let left: [Float]
    let right: [Float]

    init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
    }
}

/// What the render thread shares with everyone else: the speed asked for,
/// where the tape is and how fast it is going, a cue waiting to be taken
/// up, and the pieces read. Numbers are atomics, so the render thread
/// never waits on them; the pieces are behind a lock held only to copy or
/// change the table.
private final class TapeShared: Sendable {
    private let targetBits = Atomic<UInt64>(0.0.bitPattern)
    private let positionBits = Atomic<UInt64>(0.0.bitPattern)
    private let rateBits = Atomic<UInt64>(0.0.bitPattern)
    private let cueBits = Atomic<UInt64>(Double.nan.bitPattern)
    private let endBits = Atomic<UInt64>(0.0.bitPattern)
    private let pieces = Mutex<[Int: TapePiece]>([:])

    var target: Double {
        get { Double(bitPattern: targetBits.load(ordering: .relaxed)) }
        set { targetBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    var position: Double {
        get { Double(bitPattern: positionBits.load(ordering: .relaxed)) }
        set { positionBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    var rate: Double {
        get { Double(bitPattern: rateBits.load(ordering: .relaxed)) }
        set { rateBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// Where the timeline ends, in seconds.
    var end: Double {
        get { Double(bitPattern: endBits.load(ordering: .relaxed)) }
        set { endBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    func cue(_ seconds: Double) {
        position = seconds
        cueBits.store(seconds.bitPattern, ordering: .releasing)
    }

    /// The cue waiting, if any, taking it.
    func takeCue() -> Double? {
        let seconds = Double(bitPattern: cueBits.exchange(Double.nan.bitPattern, ordering: .acquiringAndReleasing))
        return seconds.isNaN ? nil : seconds
    }

    var allPieces: [Int: TapePiece] { pieces.withLock { $0 } }
    var pieceIndexes: Set<Int> { Set(allPieces.keys) }

    func store(_ piece: TapePiece, at index: Int) {
        pieces.withLock { $0[index] = piece }
    }

    func dropPieces(where shouldDrop: (Int) -> Bool) {
        pieces.withLock { table in
            for index in table.keys where shouldDrop(index) { table[index] = nil }
        }
    }

    func clearPieces() {
        pieces.withLock { $0 = [:] }
    }
}

/// The render thread's side: the transport, touched only there.
private final class TapeHead: @unchecked Sendable {
    private var transport = TapeTransport(sampleRate: TapeScrub.sampleRate)

    func render(shared: TapeShared, frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        if let cue = shared.takeCue() { transport.cue(cue * TapeScrub.sampleRate) }
        transport.render(
            target: shared.target, end: shared.end * TapeScrub.sampleRate, pieces: shared.allPieces,
            frames: frames, left: left, right: right
        )
        shared.position = transport.position / TapeScrub.sampleRate
        shared.rate = transport.rate
    }
}

/// Moves a playback head over the mix one output frame at a time and says
/// what it hears. The speed glides toward the one asked for, the head
/// reads between samples (cubic, Hermite), and the level fades in and out
/// below `TapeScrub.quiet`. It stops at either end of the timeline.
struct TapeTransport {
    let sampleRate: Double
    /// Where the head is, in frames of the timeline at `sampleRate`.
    private(set) var position = 0.0
    /// How fast it goes now: frames of the timeline per frame played.
    private(set) var rate = 0.0
    private var gain = 0.0
    /// How much of the way to the speed asked for each frame goes.
    private let glide: Double
    /// The same for the level, faster.
    private let fade: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        glide = 1 - exp(-1 / (TapeScrub.glide * sampleRate))
        fade = 1 - exp(-1 / (0.005 * sampleRate))
    }

    /// Puts the head at `frame`, at rest.
    mutating func cue(_ frame: Double) {
        position = max(0, frame)
        rate = 0
        gain = 0
    }

    /// Plays `frames` frames into `left` and `right`, heading for `target`
    /// speed, with the timeline ending at frame `end`.
    mutating func render(
        target: Double, end: Double, pieces: [Int: TapePiece], frames: Int,
        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    ) {
        var reader = PieceReader(pieces: pieces, pieceFrames: Int(TapeScrub.pieceSeconds * sampleRate))
        for frame in 0..<frames {
            rate += (target - rate) * glide
            if abs(target - rate) < 1e-4 { rate = target }
            position += rate
            if position <= 0 {
                position = 0
                rate = max(0, rate)
            }
            if position >= end {
                position = max(0, end)
                rate = min(0, rate)
            }
            gain += (min(1, abs(rate) / TapeScrub.quiet) - gain) * fade
            let sample = reader.sample(at: position)
            left[frame] = sample.left * Float(gain)
            right[frame] = sample.right * Float(gain)
        }
    }
}

/// Reads the mix at any position out of the pieces, between samples too.
private struct PieceReader {
    let pieces: [Int: TapePiece]
    let pieceFrames: Int
    private var index = -1
    private var piece: TapePiece?

    init(pieces: [Int: TapePiece], pieceFrames: Int) {
        self.pieces = pieces
        self.pieceFrames = pieceFrames
    }

    mutating func sample(at position: Double) -> (left: Float, right: Float) {
        let whole = Int(position.rounded(.down))
        let t = Float(position - Double(whole))
        let a = frame(whole - 1), b = frame(whole), c = frame(whole + 1), d = frame(whole + 2)
        return (Self.hermite(a.left, b.left, c.left, d.left, t), Self.hermite(a.right, b.right, c.right, d.right, t))
    }

    /// The cubic through `y1` and `y2` that `y0` and `y3` give a slope.
    private static func hermite(_ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float, _ t: Float) -> Float {
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * t + c2) * t + c1) * t + y1
    }

    private mutating func frame(_ n: Int) -> (left: Float, right: Float) {
        guard n >= 0 else { return (0, 0) }
        let wanted = n / pieceFrames
        if wanted != index {
            index = wanted
            piece = pieces[wanted]
        }
        guard let piece else { return (0, 0) }
        let offset = n - wanted * pieceFrames
        guard offset < piece.left.count else { return (0, 0) }
        return (piece.left[offset], piece.right[offset])
    }
}
