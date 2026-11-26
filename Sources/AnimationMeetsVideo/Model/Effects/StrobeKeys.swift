import Foundation

// Strobe Keys (see docs/keyframing-effects.md, "Strobe Keys in detail"):
// a repeating pulse, each an attack, decay, sustain and release from Min
// to Max and back, written as keyframes at the pulse's corners. This is
// the arithmetic, in seconds and frames from the start of the effect's
// range; `Keyframing.swift` reads the settings and writes the keyframes.
// Levels here run from 0 (Min) to 1 (Max), more for an accented pulse.

/// Where Strobe Keys' pulses start.
enum StrobeTiming: String, CaseIterable, Identifiable, Sendable {
    /// On beats of a Sound or Music layer's beat map, or between them.
    case beats
    /// Every so many frames of the timeline.
    case frames
    /// So many times a second.
    case perSecond

    var id: Self { self }

    var name: String {
        switch self {
        case .beats: "Beats"
        case .frames: "Every N Frames"
        case .perSecond: "Per Second"
        }
    }
}

/// How many pulses Strobe Keys puts in each span of its beats.
enum BeatDivision: String, CaseIterable, Identifiable, Sendable {
    case whole, half, third, quarter, sixth, eighth

    var id: Self { self }

    var name: String {
        switch self {
        case .whole: "Whole"
        case .half: "1/2"
        case .third: "1/3"
        case .quarter: "1/4"
        case .sixth: "1/6"
        case .eighth: "1/8"
        }
    }

    var parts: Int {
        switch self {
        case .whole: 1
        case .half: 2
        case .third: 3
        case .quarter: 4
        case .sixth: 6
        case .eighth: 8
        }
    }
}

/// What Strobe Keys' envelope times are measured in.
enum StrobeTimes: String, CaseIterable, Identifiable, Sendable {
    /// A share of the time to the next pulse, so pulses stretch with the
    /// tempo.
    case share
    /// Frames of the timeline: exact, but the same at any tempo.
    case frames

    var id: Self { self }

    var name: String {
        switch self {
        case .share: "Share of Interval"
        case .frames: "Frames"
        }
    }
}

/// How one stage of Strobe Keys' envelope moves.
enum StrobeCurve: String, CaseIterable, Identifiable, Sendable {
    case linear
    /// Slow at both ends.
    case eased
    /// Fast at first, then settling, as a flash of light dies away.
    case exponential

    var id: Self { self }

    var name: String {
        switch self {
        case .linear: "Linear"
        case .eased: "Eased"
        case .exponential: "Exponential"
        }
    }
}

/// What Strobe Keys does when a pulse's envelope runs past the next pulse.
enum StrobeOverlap: String, CaseIterable, Identifiable, Sendable {
    /// The pulse is cut short, and the next starts from Min.
    case cut
    /// The next starts from wherever the last had reached.
    case retrigger

    var id: Self { self }

    var name: String {
        switch self {
        case .cut: "Cut"
        case .retrigger: "Retrigger"
        }
    }
}

/// One step of a Strobe Keys pattern.
enum StrobeStep: Equatable, Sendable {
    case on, off, accent

    /// The steps of a pattern as typed: `x` on, `X` accented, `.` or `-`
    /// off; anything else (spaces, bar lines) is left out.
    static func steps(of pattern: String) -> [StrobeStep] {
        pattern.compactMap { character -> StrobeStep? in
            switch character {
            case "x", "o": .on
            case "X", "O": .accent
            case ".", "-", "_": .off
            default: nil
            }
        }
    }
}

enum StrobeKeys {
    /// A pulse: when it starts and the time to the next (in seconds from
    /// the start of the range, before swing), how high it reaches (1 is
    /// Max), and its number in the train, which swing, skip chance and the
    /// pattern read.
    struct Pulse: Equatable {
        var time: Double
        var interval: Double
        var height: Double
        var index: Int
        /// The step of the pattern it falls on, counted from the bar's
        /// start when timed to beats.
        var step: Int
        /// Whether it falls on a downbeat, for the accent.
        var isDownbeat = false
    }

    /// The envelope of every pulse.
    struct Envelope: Equatable {
        var times = StrobeTimes.share
        /// As a share of the interval (0...1) or in frames, as `times` says.
        var attack = 0.0
        var decay = 0.0
        var sustainFor = 0.25
        var release = 0.25
        /// The level held after the decay, as a share of the peak.
        var sustain = 1.0
        var attackCurve = StrobeCurve.linear
        var decayCurve = StrobeCurve.exponential
        var releaseCurve = StrobeCurve.exponential
        var overlap = StrobeOverlap.cut

        /// The four stages of a pulse, in seconds.
        func seconds(interval: Double, frame: Double) -> (attack: Double, decay: Double, sustainFor: Double, release: Double) {
            let scale = times == .share ? max(interval, 0) : frame
            return (max(attack, 0) * scale, max(decay, 0) * scale, max(sustainFor, 0) * scale, max(release, 0) * scale)
        }
    }

    /// A corner of the strobe's curve, on a frame of the range (0 is its
    /// first), and how the curve leaves it for the next: along a curve, or
    /// held until the next, then jumping.
    struct Node: Equatable {
        enum Leaving: Equatable {
            case curve(StrobeCurve)
            case hold
        }

        var frame: Int
        var level: Double
        var leaving: Leaving
    }

    // MARK: Timing

    /// Pulses on beats: from the first of `beats` at or after the range's
    /// start (`first`), `shift` beats on, every `every` beats split into
    /// `parts`, each placed between the beats on either side so it follows
    /// a tempo ramp, and past the last beat at its spacing. `beats` are in
    /// seconds from the start of the range, earlier ones too; `downbeats`
    /// says which are. Up to the first past `duration`.
    static func beatPulses(
        _ beats: [Double], downbeats: [Bool], first: Int, every: Int, parts: Int, shift: Double, duration: Double
    ) -> [Pulse] {
        guard !beats.isEmpty, first < beats.count else { return [] }
        let step = Double(max(every, 1)) / Double(max(parts, 1))
        var times: [(time: Double, isDownbeat: Bool)] = []
        // A beat map of one beat has no spacing to follow: just it.
        if beats.count == 1 {
            if shift == 0 { times.append((beats[0], downbeats.first ?? false)) }
        } else {
            var n = 0
            while n < 100_000 {
                let position = shift + Double(n) * step
                let whole = floor(position + 1e-9)
                let fraction = max(position - whole, 0)
                let i = first + Int(whole)
                let j = min(max(i, 0), beats.count - 2)
                let time = beats[j] + (beats[j + 1] - beats[j]) * (Double(i - j) + fraction)
                let onBeat = fraction < 1e-9 && i >= 0 && i < beats.count
                times.append((time, onBeat && i < downbeats.count && downbeats[i]))
                if time > duration { break }
                n += 1
            }
        }
        return pulses(times, duration: duration, barsFromDownbeats: true)
    }

    /// Pulses every `frames` frames, the first `shift` frames from the
    /// start, up to the first past `duration`.
    static func framePulses(every frames: Int, shift: Double, frame: Double, duration: Double) -> [Pulse] {
        guard frame > 0 else { return [] }
        let spacing = Double(max(frames, 1)) * frame
        var times: [(time: Double, isDownbeat: Bool)] = []
        var n = 0
        while n < 1_000_000 {
            let time = shift * frame + Double(n) * spacing
            times.append((time, false))
            if time > duration { break }
            n += 1
        }
        return pulses(times, duration: duration, barsFromDownbeats: false)
    }

    /// Pulses at a rate that may change: one each time `cycles` (the
    /// integrated rate at each of `elapsed`, from 0) passes a whole number,
    /// at the last rate past the end, all moved `shift` seconds.
    static func ratePulses(cycles: [Double], elapsed: [Double], lastRate: Double, shift: Double, duration: Double) -> [Pulse] {
        guard let lastCycles = cycles.last, let lastElapsed = elapsed.last, cycles.count == elapsed.count else { return [] }
        var times: [(time: Double, isDownbeat: Bool)] = []
        var k = 0
        var n = 0
        while n < 1_000_000 {
            let target = Double(n)
            var time: Double
            if target <= lastCycles {
                while k + 1 < cycles.count, cycles[k + 1] < target { k += 1 }
                if target <= cycles[0] {
                    time = elapsed[0]
                } else {
                    let a = cycles[k], b = cycles[min(k + 1, cycles.count - 1)]
                    let fraction = b > a ? (target - a) / (b - a) : 0
                    time = elapsed[k] + (elapsed[min(k + 1, elapsed.count - 1)] - elapsed[k]) * fraction
                }
            } else {
                guard lastRate > 0 else { break }
                time = lastElapsed + (target - lastCycles) / lastRate
            }
            time += shift
            times.append((time, false))
            if time > duration { break }
            n += 1
        }
        return pulses(times, duration: duration, barsFromDownbeats: false)
    }

    /// Pulses at `times`, each with the time to the next as its interval
    /// (the last keeps the one before it, or the range's length) and its
    /// step of the pattern: counted from the last downbeat when
    /// `barsFromDownbeats`, else from the first pulse.
    private static func pulses(_ times: [(time: Double, isDownbeat: Bool)], duration: Double, barsFromDownbeats: Bool) -> [Pulse] {
        var pulses: [Pulse] = []
        var step = 0
        for (n, entry) in times.enumerated() {
            if barsFromDownbeats, entry.isDownbeat { step = 0 }
            let interval: Double
            if n + 1 < times.count {
                interval = times[n + 1].time - entry.time
            } else if n > 0 {
                interval = entry.time - times[n - 1].time
            } else {
                interval = max(duration - entry.time, 0)
            }
            pulses.append(Pulse(time: entry.time, interval: interval, height: 1, index: n, step: step, isDownbeat: entry.isDownbeat))
            step += 1
        }
        return pulses
    }

    // MARK: Variation

    /// How the pulses are varied, each setting as it is at a pulse.
    struct Variation {
        /// Every other pulse is late by this share of its interval.
        var swing: (Pulse) -> Double = { _ in 0 }
        /// The share of pulses left out (0...1), by `seed`.
        var skipChance: (Pulse) -> Double = { _ in 0 }
        var seed: UInt64 = 1
        var pattern: [StrobeStep] = []
        /// How much higher an accented pulse reaches, as a share of its
        /// height.
        var accent: (Pulse) -> Double = { _ in 0.5 }
        /// Whether downbeats are accented, as the pattern's `X` steps are.
        var accentsDownbeats = false
        /// Seconds of fade at each end of the range.
        var fade = 0.0
    }

    /// The pulses as varied: every other one late by its swing, those the
    /// pattern turns off or the skip chance leaves out taken away, those
    /// accented raised, and each faded at the ends of the range.
    static func varied(_ pulses: [Pulse], by variation: Variation, duration: Double) -> [Pulse] {
        let pattern = variation.pattern
        return pulses.compactMap { original -> Pulse? in
            var pulse = original
            let step = pattern.isEmpty ? StrobeStep.on : pattern[pulse.step.modulo(pattern.count)]
            if step == .off { return nil }
            let chance = variation.skipChance(pulse)
            if chance > 0 {
                let roll = Double(KeyframeGenerators.hash(variation.seed &* 0x9E37 &+ UInt64(bitPattern: Int64(pulse.index))) >> 11)
                    / Double(UInt64(1) << 53)
                if roll < chance { return nil }
            }
            if pulse.index % 2 == 1 { pulse.time += variation.swing(pulse) * pulse.interval }
            if step == .accent || (variation.accentsDownbeats && pulse.isDownbeat) { pulse.height *= 1 + variation.accent(pulse) }
            pulse.height *= KeyframeGenerators.fadeEnvelope(elapsed: pulse.time, total: duration, fade: variation.fade)
            return pulse
        }
    }

    // MARK: Corners

    /// The corners of the curve the pulses make, each on its nearest frame
    /// (`frame` seconds long), with jumps held to the frame before them:
    /// a stage of no length is a hard step, held rather than ramping
    /// between frames. Before the first pulse it is at Min.
    static func nodes(_ pulses: [Pulse], envelope: Envelope, frame: Double) -> [Node] {
        nodes(pulses, envelopes: Array(repeating: envelope, count: pulses.count), frame: frame)
    }

    /// The same, with an envelope for each pulse, as its settings are where
    /// it starts.
    static func nodes(_ pulses: [Pulse], envelopes: [Envelope], frame: Double) -> [Node] {
        guard frame > 0, !pulses.isEmpty, envelopes.count == pulses.count else { return [] }
        // Points in order, two at one frame being a jump; each with how the
        // curve leaves it.
        var points: [(frame: Int, level: Double, leaving: StrobeCurve)] = []
        func onFrame(_ seconds: Double) -> Int { Int((seconds / frame).rounded()) }
        let starts = pulses.map { onFrame($0.time) }
        // At Min until the first pulse.
        points.append((starts[0] - 1, 0, .linear))
        for (n, pulse) in pulses.enumerated() {
            let start = starts[n]
            let envelope = envelopes[n]
            let stages = envelope.seconds(interval: pulse.interval, frame: frame)
            let peakAt = max(onFrame(pulse.time + stages.attack), start)
            let decayedAt = max(onFrame(pulse.time + stages.attack + stages.decay), peakAt)
            let heldTo = max(onFrame(pulse.time + stages.attack + stages.decay + stages.sustainFor), decayedAt)
            let releasedAt = max(onFrame(pulse.time + stages.attack + stages.decay + stages.sustainFor + stages.release), heldTo)
            let sustain = pulse.height * envelope.sustain.clamped(between: 0, and: 1)
            // A decay of no length goes straight to the sustain: the peak
            // is never seen.
            let peak = decayedAt == peakAt ? sustain : pulse.height
            // Retrigger starts from wherever the last pulse had reached;
            // otherwise each starts from Min.
            let from = envelope.overlap == .retrigger ? level(at: Double(start), of: points) : 0
            points.removeAll { $0.frame > start }
            if let last = points.last, last.frame < start {
                points.append((start, level(at: Double(start), of: points + [last]), .linear))
            }
            var pulsePoints: [(frame: Int, level: Double, leaving: StrobeCurve)] = [(start, from, envelope.attackCurve)]
            pulsePoints.append((peakAt, peak, envelope.decayCurve))
            pulsePoints.append((decayedAt, sustain, .linear))
            pulsePoints.append((heldTo, sustain, envelope.releaseCurve))
            pulsePoints.append((releasedAt, 0, .linear))
            // Cut short where the next pulse starts.
            if n + 1 < pulses.count {
                let next = starts[n + 1]
                if let past = pulsePoints.firstIndex(where: { $0.frame > next }) {
                    let reached = level(at: Double(next), of: Array(pulsePoints[...past]))
                    pulsePoints.removeSubrange(past...)
                    pulsePoints.append((next, reached, .linear))
                }
            }
            points += pulsePoints
        }
        return normalized(points)
    }

    /// The points made nodes: repeats left out, and at each jump the curve
    /// coming in ended on the frame before and held there.
    private static func normalized(_ points: [(frame: Int, level: Double, leaving: StrobeCurve)]) -> [Node] {
        var nodes: [Node] = []
        for point in points {
            guard let last = nodes.last else {
                nodes.append(Node(frame: point.frame, level: point.level, leaving: .curve(point.leaving)))
                continue
            }
            if point.frame < last.frame { continue }
            if point.frame == last.frame {
                if abs(point.level - last.level) < 1e-12 {
                    // The same corner again: it leaves as the later says.
                    nodes[nodes.count - 1].leaving = .curve(point.leaving)
                    continue
                }
                // A jump at this frame: the curve coming in ends a frame
                // before, held there.
                nodes.removeLast()
                if let before = nodes.last {
                    if before.frame < point.frame - 1, case .curve(let curve) = before.leaving {
                        let fraction = Double(point.frame - 1 - before.frame) / Double(point.frame - before.frame)
                        let level = before.level + (last.level - before.level) * shape(curve, fraction)
                        nodes.append(Node(frame: point.frame - 1, level: level, leaving: .hold))
                    } else {
                        nodes[nodes.count - 1].leaving = .hold
                    }
                } else {
                    nodes.append(Node(frame: point.frame - 1, level: last.level, leaving: .hold))
                }
                nodes.append(Node(frame: point.frame, level: point.level, leaving: .curve(point.leaving)))
                continue
            }
            nodes.append(Node(frame: point.frame, level: point.level, leaving: .curve(point.leaving)))
        }
        return nodes
    }

    /// The level at `frame` of points in order, as `normalized` would join
    /// them; before the first, the first's level, after the last, the
    /// last's.
    private static func level(at frame: Double, of points: [(frame: Int, level: Double, leaving: StrobeCurve)]) -> Double {
        guard let first = points.first else { return 0 }
        if frame <= Double(first.frame) { return first.level }
        var i = points.count - 1
        while i > 0, Double(points[i].frame) > frame { i -= 1 }
        // The last of several at one frame.
        guard i + 1 < points.count else { return points[i].level }
        let a = points[i], b = points[i + 1]
        guard b.frame > a.frame else { return b.level }
        return a.level + (b.level - a.level) * shape(a.leaving, (frame - Double(a.frame)) / Double(b.frame - a.frame))
    }

    /// The level at `frame` (which needn't be whole) of `nodes`: Min before
    /// the first, the last's level after it.
    static func level(at frame: Double, of nodes: [Node]) -> Double {
        guard let first = nodes.first else { return 0 }
        if frame < Double(first.frame) { return 0 }
        // The last node at or before the frame.
        var low = 0, high = nodes.count
        while low < high {
            let middle = (low + high) / 2
            if Double(nodes[middle].frame) <= frame { low = middle + 1 } else { high = middle }
        }
        let i = low - 1
        guard i + 1 < nodes.count else { return nodes[i].level }
        let a = nodes[i], b = nodes[i + 1]
        switch a.leaving {
        case .hold: return a.level
        case .curve(let curve):
            return a.level + (b.level - a.level) * shape(curve, (frame - Double(a.frame)) / Double(b.frame - a.frame))
        }
    }

    /// How far along a stage of `curve` the level is, `progress` of the
    /// way through it in time.
    @inline(__always)
    static func shape(_ curve: StrobeCurve, _ progress: Double) -> Double {
        let u = progress.clamped(between: 0, and: 1)
        switch curve {
        case .linear: return u
        case .eased: return u * u * (3 - 2 * u)
        case .exponential: return (1 - exp(-exponentialRate * u)) / (1 - exp(-exponentialRate))
        }
    }

    /// How quickly an exponential stage settles: by the end it has moved
    /// all but under 1% of the way at its starting speed.
    static let exponentialRate = 5.0

    /// The eases that draw a stage of `curve` between two keyframes: how it
    /// leaves the first and arrives at the second. Exponential is near
    /// enough a curve that leaves fast and arrives slowly, without
    /// overshooting.
    static func eases(_ curve: StrobeCurve) -> (leaving: KeyframeEase?, arriving: KeyframeEase?) {
        switch curve {
        case .linear: (nil, nil)
        case .eased: (.easy, .easy)
        case .exponential: (KeyframeEase(influence: 0.2, speed: 4), KeyframeEase(influence: 0.6, speed: 0))
        }
    }

    // MARK: Safety

    /// Whether more than `limit` of the pulses start within any second
    /// (see docs/psychedelic-effects.md, "Safety: flashing").
    static func flashesTooFast(_ pulses: [Pulse], limit: Int = 3) -> Bool {
        let times = pulses.map(\.time).sorted()
        var first = 0
        for last in times.indices {
            while times[last] - times[first] >= 1 { first += 1 }
            if last - first + 1 > limit { return true }
        }
        return false
    }
}
