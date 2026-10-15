import CoreMedia
import os
import Foundation

// Time and Shutter (see docs/effects.md, "Time and Shutter"): what a clip
// does to time, above its stack, and what it does with the finished picture,
// below its transitions. Neither is an effect in the stack.

/// How a retimed clip gets frames between the source's own.
enum FrameBlending: String, CaseIterable, Identifiable, Sendable {
    /// The nearest frame is shown.
    case off
    /// The two nearest frames are mixed.
    case blend
    /// In-between frames built from optical flow. Too slow to draw live, so
    /// the viewer shows it as Blend until a stretch is rendered.
    case opticalFlow

    var id: Self { self }

    var name: String {
        switch self {
        case .off: "Off"
        case .blend: "Blend"
        case .opticalFlow: "Optical Flow"
        }
    }
}

/// What a retimed clip's sound does while its speed isn't 100%.
enum SoundMode: String, CaseIterable, Identifiable, Sendable {
    /// Plays at the new speed at its own pitch.
    case keepPitch
    /// Speeds up and slows down like tape, pitch and all.
    case changePitch
    /// Silent.
    case mute

    var id: Self { self }

    var name: String {
        switch self {
        case .keepPitch: "Keep Pitch"
        case .changePitch: "Change Pitch"
        case .mute: "Mute"
        }
    }
}

/// Earlier source frames layered under the current one.
struct Echo: Equatable, Sendable {
    static let countRange = 1...16
    static let decayRange = 0.0...1.0

    var count = 4
    /// The timeline time between one copy and the next.
    var delay: CMTime
    /// How strong each copy is next to the one in front of it.
    var decay = 0.6

    var clamped: Echo {
        Echo(
            count: min(max(count, Self.countRange.lowerBound), Self.countRange.upperBound),
            delay: CMTimeMaximum(delay, CMTime(value: 1, timescale: 1000)),
            decay: min(max(decay, Self.decayRange.lowerBound), Self.decayRange.upperBound)
        )
    }
}

/// What a clip does to time, above its stack: which source frames the rest
/// of the clip receives.
struct ClipTime: Equatable, Sendable {
    /// A percentage, 100 playing at the source's own speed. Keyframed in the
    /// clip's source time (see `TimelineClip.timelineTime(forSourceTime:)`).
    var speed = AnimatedValue(100.0)
    var frameBlending = FrameBlending.off
    var echo: Echo?
    var sound = SoundMode.keepPitch

    static let speedRange = 1.0...10_000.0

    var isDefault: Bool { self == ClipTime() }
}

/// Motion blur: the finished clip drawn at several moments across the
/// shutter and averaged.
struct MotionBlur: Equatable, Sendable {
    static let angleRange = 0.0...360.0
    static let sampleRange = 2...64

    /// How much of a frame the shutter is open, in degrees (180 is half).
    var angle = 180.0
    var samples = 8

    var clamped: MotionBlur {
        MotionBlur(
            angle: min(max(angle, Self.angleRange.lowerBound), Self.angleRange.upperBound),
            samples: min(max(samples, Self.sampleRange.lowerBound), Self.sampleRange.upperBound)
        )
    }
}

/// Copies of the finished clip from earlier moments, movement and all.
struct Trails: Equatable, Sendable {
    var count = 4
    var delay: CMTime
    var decay = 0.6

    var clamped: Trails {
        let echo = Echo(count: count, delay: delay, decay: decay).clamped
        return Trails(count: echo.count, delay: echo.delay, decay: echo.decay)
    }
}

/// What a clip does with its finished picture, below its transitions.
struct ClipShutter: Equatable, Sendable {
    var motionBlur: MotionBlur?
    var trails: Trails?

    var isOff: Bool { motionBlur == nil && trails == nil }
}

// MARK: - Timing

extension TimelineClip {
    /// Whether the clip plays at anything but its source's own speed.
    var isRetimed: Bool { time.speed != AnimatedValue(100.0) }

    /// How fast the clip plays at a moment of its source, as a percentage.
    func speed(atSource sourceTime: CMTime) -> Double {
        min(max(time.speed.value(at: sourceTime), ClipTime.speedRange.lowerBound), ClipTime.speedRange.upperBound)
    }

    /// The timeline time the source takes to play from `a` to `b` (negative
    /// when `b` is before `a`): the length of a clip's source range at its
    /// speed. Speed is a rate, so a clip at 50% takes twice as long.
    func timelineLength(ofSource a: CMTime, to b: CMTime) -> CMTime {
        if b < a { return CMTimeMultiply(timelineLength(ofSource: b, to: a), multiplier: -1) }
        let span = CMTimeSubtract(b, a)
        guard !time.speed.isAnimated else {
            let integral = SpeedIntegral.of(time.speed)
            return CMTime(seconds: integral.length(from: a.seconds, to: b.seconds), preferredTimescale: 240_000)
        }
        let speed = speed(atSource: a)
        if speed == 100 { return span }
        if speed.rounded() == speed, speed >= 1 { return CMTimeMultiplyByRatio(span, multiplier: 100, divisor: Int32(speed)) }
        return CMTimeMultiplyByFloat64(span, multiplier: 100 / speed)
    }

    /// How long the clip lasts on the timeline.
    var placedDuration: CMTime {
        timelineLength(ofSource: trimStart, to: trimEnd)
    }

    /// The timeline time the source's `sourceTime` plays at.
    func timelineTime(forSourceTime sourceTime: CMTime) -> CMTime {
        CMTimeAdd(startOffset, timelineLength(ofSource: trimStart, to: sourceTime))
    }

    /// The moment of the source playing at `time` in the timeline.
    func sourceTime(atTimelineTime time: CMTime) -> CMTime {
        let elapsed = CMTimeSubtract(time, startOffset)
        guard self.time.speed.isAnimated else {
            let speed = speed(atSource: trimStart)
            if speed == 100 { return CMTimeAdd(trimStart, elapsed) }
            if speed.rounded() == speed { return CMTimeAdd(trimStart, CMTimeMultiplyByRatio(elapsed, multiplier: Int32(speed), divisor: 100)) }
            return CMTimeAdd(trimStart, CMTimeMultiplyByFloat64(elapsed, multiplier: speed / 100))
        }
        // Playing the source takes more time the more of it has played, so
        // find where the time that has passed is used up.
        let integral = SpeedIntegral.of(self.time.speed)
        let anchor = trimStart.seconds
        return CMTime(seconds: integral.source(atIntegral: integral.at(anchor) + elapsed.seconds), preferredTimescale: 240_000)
    }

    /// How much source plays in `length` of timeline time from the clip's
    /// start (what trimming the end to that length leaves).
    func sourceDuration(forPlaced length: CMTime) -> CMTime {
        CMTimeSubtract(sourceTime(atTimelineTime: CMTimeAdd(startOffset, length)), trimStart)
    }

    /// How far a drag of the footage by `placedDelta` of timeline time moves
    /// it in the source, at the speed the clip starts at.
    func sourceDelta(forPlacedDelta placedDelta: CMTime) -> CMTime {
        let speed = speed(atSource: trimStart)
        if speed == 100 { return placedDelta }
        return CMTimeMultiplyByFloat64(placedDelta, multiplier: speed / 100)
    }
}

/// The time the source takes to play, as a function of how far into it:
/// the integral of `100 / speed` over source seconds, measured from the
/// speed's first keyframe. Outside the keyframes the speed is constant, so
/// the integral is a line; between them it is added up by Simpson's rule,
/// and the total up to each keyframe is kept, so finding the time at any
/// point integrates only the piece it is in.
struct SpeedIntegral {
    private let speed: AnimatedValue<Double>
    private let times: [Double]
    /// The integral at each keyframe.
    private let totals: [Double]

    static let stepsPerPiece = 24

    /// The grid the rate's times are cut to, per second.
    static let rateTimescale: Int32 = 1_000_000_000

    /// The few most recently used, since a speed is asked about over and
    /// over (every clip block, frame and render key) between edits.
    private static let recent = OSAllocatedUnfairLock(initialState: [SpeedIntegral]())

    /// The integral of `speed`, from the cache if it was made lately.
    static func of(_ speed: AnimatedValue<Double>) -> SpeedIntegral {
        if let found = recent.withLock({ $0.first { $0.speed == speed } }) { return found }
        let made = SpeedIntegral(speed)
        recent.withLock { cache in
            cache.append(made)
            if cache.count > 8 { cache.removeFirst() }
        }
        return made
    }

    private init(_ speed: AnimatedValue<Double>) {
        self.speed = speed
        times = speed.keyframes.map(\.time.seconds)
        var totals = [0.0]
        for index in times.indices.dropFirst() {
            totals.append(totals[index - 1] + Self.simpson(speed, from: times[index - 1], to: times[index]))
        }
        self.totals = totals
    }

    private static func rate(_ speed: AnimatedValue<Double>, at seconds: Double) -> Double {
        // A fine timescale, since each time is cut to the grid: at 1 / 240000
        // the cuts add up to about 1e-5 s over a long piece, more than the
        // result is rounded by.
        let value = speed.value(at: CMTime(seconds: seconds, preferredTimescale: rateTimescale))
        return 100 / min(max(value, ClipTime.speedRange.lowerBound), ClipTime.speedRange.upperBound)
    }

    private static func simpson(_ speed: AnimatedValue<Double>, from low: Double, to high: Double) -> Double {
        guard high > low else { return 0 }
        let steps = stepsPerPiece
        let h = (high - low) / Double(steps)
        var sum = rate(speed, at: low) + rate(speed, at: high)
        for i in 1..<steps { sum += rate(speed, at: low + Double(i) * h) * (i.isMultiple(of: 2) ? 2 : 4) }
        return sum * h / 3
    }

    /// The integral at `seconds` of source time.
    func at(_ seconds: Double) -> Double {
        guard let first = times.first, let last = times.last else { return seconds * Self.rate(speed, at: 0) }
        if seconds <= first { return (seconds - first) * Self.rate(speed, at: first) }
        if seconds >= last { return totals[totals.count - 1] + (seconds - last) * Self.rate(speed, at: last) }
        var index = 0
        while index + 1 < times.count - 1, times[index + 1] <= seconds { index += 1 }
        return totals[index] + Self.simpson(speed, from: times[index], to: seconds)
    }

    /// The most the timeline time a result may be off by, in seconds. It is
    /// far below a frame and below the 240000 timescale the answer is
    /// rounded to.
    static let timeTolerance = 1e-8

    /// The source time, in seconds, whose integral is `target`: the inverse
    /// of `at`. The rate is always positive, so `at` only rises and the
    /// answer is the only one. The totals at the keyframes say which piece
    /// it is in; there it is found by Newton's method, whose step is the
    /// timeline time left over divided by the rate. A step that leaves the
    /// bracket the totals and earlier steps have narrowed, or that fails to
    /// halve the error, is replaced by bisection, so it always ends.
    func source(atIntegral target: Double) -> Double {
        guard let first = times.first, let last = times.last else { return target / Self.rate(speed, at: 0) }
        if target <= 0 { return first + target / Self.rate(speed, at: first) }
        let end = totals[totals.count - 1]
        if target >= end { return last + (target - end) / Self.rate(speed, at: last) }
        // The last keyframe whose total is at or below the target.
        var low = 0, high = totals.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if totals[middle] <= target { low = middle } else { high = middle }
        }
        if totals[low] == target { return times[low] }
        let remaining = target - totals[low]
        var lower = times[low], upper = times[low + 1]
        var guess = lower + (upper - lower) * remaining / (totals[low + 1] - totals[low])
        var lastError = Double.infinity
        for _ in 0..<100 {
            let error = Self.simpson(speed, from: times[low], to: guess) - remaining
            if abs(error) <= Self.timeTolerance || upper - lower <= 1e-12 { break }
            if error < 0 { lower = guess } else { upper = guess }
            var next = guess - error / Self.rate(speed, at: guess)
            if !(next > lower && next < upper) || abs(error) > lastError / 2 { next = (lower + upper) / 2 }
            lastError = abs(error)
            guess = next
        }
        return guess
    }

    /// The time in seconds the source takes to play from `a` to `b`.
    func length(from a: Double, to b: Double) -> Double {
        at(b) - at(a)
    }
}

// MARK: - Editing

extension EditingProject {
    /// Applies `change` to a clip's time settings. Retiming changes how long
    /// the clip lasts, so its end is put back on a frame and the clips after
    /// it on its layer move by as much as its end did, as when it is trimmed.
    mutating func editTime(
        ofClip clipID: UUID,
        in timelineID: UUID,
        layer layerID: UUID,
        _ change: (inout ClipTime) -> Void
    ) {
        guard let timeline = timeline(id: timelineID),
              var clip = timeline.layer(id: layerID)?.clips.first(where: { $0.id == clipID })
        else {
            return
        }
        var settings = clip.time
        change(&settings)
        settings.speed = AnimatedValue(
            Self.clampedSpeed(settings.speed.value),
            keyframes: settings.speed.keyframes.map {
                Keyframe(time: $0.time, value: Self.clampedSpeed($0.value), easeIn: $0.easeIn, easeOut: $0.easeOut)
            }
        )
        settings.echo = settings.echo?.clamped
        guard settings != clip.time else { return }
        clip.time = settings
        applyRipple(coveringWholeFrames(clip, in: timeline), in: timelineID, layer: layerID)
    }

    private static func clampedSpeed(_ speed: Double) -> Double {
        min(max(speed, ClipTime.speedRange.lowerBound), ClipTime.speedRange.upperBound)
    }
}
