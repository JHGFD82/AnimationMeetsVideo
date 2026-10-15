import CoreMedia
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
            return Self.seconds(integratingReciprocalSpeed: time.speed, from: a, to: b)
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
        let target = elapsed.seconds
        let anchor = trimStart.seconds
        let fastest = ClipTime.speedRange.upperBound / 100
        var low = target >= 0 ? anchor : anchor + target * fastest - 1e-6
        var high = target >= 0 ? anchor + target * fastest + 1e-6 : anchor
        for _ in 0..<48 {
            let middle = (low + high) / 2
            let length = timelineLength(ofSource: trimStart, to: CMTime(seconds: middle, preferredTimescale: 240_000)).seconds
            if length < target { low = middle } else { high = middle }
        }
        return CMTime(seconds: (low + high) / 2, preferredTimescale: 240_000)
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

    /// Time in seconds of `100 / speed` integrated over the source from `a`
    /// to `b`, in pieces that start and end at keyframes.
    private static func seconds(integratingReciprocalSpeed speed: AnimatedValue<Double>, from a: CMTime, to b: CMTime) -> CMTime {
        var edges = [a.seconds]
        edges += speed.keyframes.map(\.time.seconds).filter { $0 > a.seconds && $0 < b.seconds }
        edges.append(b.seconds)
        func rate(_ seconds: Double) -> Double {
            100 / min(max(speed.value(at: CMTime(seconds: seconds, preferredTimescale: 240_000)), ClipTime.speedRange.lowerBound), ClipTime.speedRange.upperBound)
        }
        var total = 0.0
        for (low, high) in zip(edges, edges.dropFirst()) where high > low {
            // Simpson's rule on an even number of steps.
            let steps = min(max(Int(((high - low) * 120).rounded(.up)) * 2, 8), 8192)
            let h = (high - low) / Double(steps)
            var sum = rate(low) + rate(high)
            for i in 1..<steps { sum += rate(low + Double(i) * h) * (i.isMultiple(of: 2) ? 2 : 4) }
            total += sum * h / 3
        }
        return CMTime(seconds: total, preferredTimescale: 240_000)
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
