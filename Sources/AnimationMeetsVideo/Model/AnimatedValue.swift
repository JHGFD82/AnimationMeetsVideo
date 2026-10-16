import CoreGraphics
import CoreMedia
import Foundation

/// A value a property can animate between: keyframed values are blended
/// linearly.
protocol Interpolatable: Equatable, Sendable {
    static func interpolate(_ from: Self, _ to: Self, fraction: Double) -> Self
}

extension Double: Interpolatable {
    static func interpolate(_ from: Double, _ to: Double, fraction: Double) -> Double {
        from + (to - from) * fraction
    }
}

/// A 2D value such as a position or a scale. 3D properties will add a `z`.
struct Vector2: Interpolatable, Hashable {
    var x: Double
    var y: Double

    static let zero = Vector2(x: 0, y: 0)

    static func interpolate(_ from: Vector2, _ to: Vector2, fraction: Double) -> Vector2 {
        Vector2(
            x: Double.interpolate(from.x, to.x, fraction: fraction),
            y: Double.interpolate(from.y, to.y, fraction: fraction)
        )
    }
}

/// One keyframe: a property's value at a time (a clip's source time, for
/// effect controls), and how the value arrives at it and leaves it (nil is linear; see
/// `KeyframeEase`).
struct Keyframe<Value: Interpolatable>: Equatable, Sendable {
    var time: CMTime
    var value: Value
    var easeIn: KeyframeEase?
    var easeOut: KeyframeEase?
}

/// A property that is either a single value or animated by keyframes.
/// With no keyframes `value` applies everywhere. With keyframes, the value
/// holds the first keyframe's value before it, the last one's after it, and
/// is blended in between, linearly or along the curve the two keyframes'
/// eases make; `value` is then unused.
///
/// A keyframe is identified by its time: a property has at most one per
/// time, so setting a value at an existing keyframe's time replaces it.
struct AnimatedValue<Value: Interpolatable>: Equatable, Sendable {
    var value: Value
    /// Sorted by time, without duplicates.
    private(set) var keyframes: [Keyframe<Value>] = []

    init(_ value: Value, keyframes: [Keyframe<Value>] = []) {
        self.value = value
        self.keyframes = Self.normalized(keyframes)
    }

    var isAnimated: Bool { !keyframes.isEmpty }

    /// The first and last keyframe times, or nil when not animated. The value
    /// is constant outside this range.
    var animatedRange: ClosedRange<CMTime>? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        return first.time...last.time
    }

    func value(at time: CMTime) -> Value {
        guard let first = keyframes.first, let last = keyframes.last else { return value }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        let next = keyframes.lowerBound(of: time) { $0.time }
        let before = keyframes[next - 1]
        let after = keyframes[next]
        let span = CMTimeSubtract(after.time, before.time).seconds
        guard span > 0 else { return after.value }
        let fraction = CMTimeSubtract(time, before.time).seconds / span
        let progress = KeyframeEase.progress(fraction, leaving: before.easeOut, arriving: after.easeIn)
        return Value.interpolate(before.value, after.value, fraction: progress)
    }

    /// The value at a time given as plain seconds, which is not cut to a
    /// CMTime grid, for numerical work (integrating a speed) that reads the
    /// curve at points of its own choosing. It agrees with `value(at:)`
    /// wherever the time is one a CMTime can say.
    func value(atSeconds seconds: Double) -> Value {
        guard let first = keyframes.first, let last = keyframes.last else { return value }
        if seconds <= first.time.seconds { return first.value }
        if seconds >= last.time.seconds { return last.value }
        // The first keyframe after `seconds`.
        var low = 1, high = keyframes.count - 1
        while low < high {
            let middle = (low + high) / 2
            if keyframes[middle].time.seconds > seconds { high = middle } else { low = middle + 1 }
        }
        let before = keyframes[low - 1]
        let after = keyframes[low]
        let span = after.time.seconds - before.time.seconds
        guard span > 0 else { return after.value }
        let progress = KeyframeEase.progress((seconds - before.time.seconds) / span, leaving: before.easeOut, arriving: after.easeIn)
        return Value.interpolate(before.value, after.value, fraction: progress)
    }

    func keyframe(at time: CMTime) -> Keyframe<Value>? {
        keyframes.first { $0.time == time }
    }

    /// The same with every keyframe `delta` later (earlier if negative).
    func shifted(by delta: CMTime) -> AnimatedValue {
        AnimatedValue(value, keyframes: keyframes.map { keyframe in
            var moved = keyframe
            moved.time = CMTimeAdd(keyframe.time, delta)
            return moved
        })
    }

    /// Sets the value at `time`: a keyframe there when animated (keeping
    /// its eases if one is already there), otherwise the single value.
    mutating func set(_ newValue: Value, at time: CMTime) {
        guard isAnimated else {
            value = newValue
            return
        }
        if let index = keyframes.firstIndex(where: { $0.time == time }) {
            keyframes[index].value = newValue
            return
        }
        keyframes.append(Keyframe(time: time, value: newValue))
        keyframes = Self.normalized(keyframes)
    }

    /// Sets how the value arrives at and leaves the keyframe at `time`.
    mutating func setEase(at time: CMTime, in easeIn: KeyframeEase?, out easeOut: KeyframeEase?) {
        guard let index = keyframes.firstIndex(where: { $0.time == time }) else { return }
        keyframes[index].easeIn = easeIn
        keyframes[index].easeOut = easeOut
    }

    /// Applies a ready-made ease to the keyframe at `time`. Ease In and
    /// Ease Out change only their own side.
    mutating func applyEase(_ preset: KeyframeEase.Preset, at time: CMTime) {
        guard let keyframe = keyframe(at: time) else { return }
        switch preset {
        case .linear: setEase(at: time, in: nil, out: nil)
        case .easeIn: setEase(at: time, in: .easy, out: keyframe.easeOut)
        case .easeOut: setEase(at: time, in: keyframe.easeIn, out: .easy)
        case .easyEase: setEase(at: time, in: .easy, out: .easy)
        }
    }

    /// Turns animation on with one keyframe holding the current value at
    /// `time`, or off, keeping the value that was showing at `time`.
    mutating func setAnimated(_ animated: Bool, at time: CMTime) {
        guard animated != isAnimated else { return }
        if animated {
            keyframes = [Keyframe(time: time, value: value)]
        } else {
            value = value(at: time)
            keyframes = []
        }
    }

    /// Adds a keyframe holding the current value at `time`, or removes the
    /// one that is there.
    mutating func toggleKeyframe(at time: CMTime) {
        if keyframe(at: time) != nil {
            removeKeyframe(at: time)
        } else if isAnimated {
            set(value(at: time), at: time)
        } else {
            setAnimated(true, at: time)
        }
    }

    /// Removing the last keyframe leaves the property set to its value.
    mutating func removeKeyframe(at time: CMTime) {
        guard let removed = keyframe(at: time) else { return }
        keyframes.removeAll { $0.time == time }
        if keyframes.isEmpty { value = removed.value }
    }

    /// Moves a keyframe in time, with its eases, replacing any keyframe
    /// already at `newTime`.
    mutating func moveKeyframe(at time: CMTime, to newTime: CMTime) {
        guard time != newTime, var moving = keyframe(at: time) else { return }
        keyframes.removeAll { $0.time == time || $0.time == newTime }
        moving.time = newTime
        keyframes.append(moving)
        keyframes = Self.normalized(keyframes)
    }

    /// Moves every keyframe to `move(time)`, with its eases. Keyframes that
    /// land on the same time merge, keeping the later one.
    mutating func moveKeyframeTimes(_ move: (CMTime) -> CMTime) {
        keyframes = Self.normalized(keyframes.map { keyframe in
            var moved = keyframe
            moved.time = move(keyframe.time)
            return moved
        })
    }

    /// Sorted, keeping the last of any keyframes that share a time.
    private static func normalized(_ keyframes: [Keyframe<Value>]) -> [Keyframe<Value>] {
        var result: [Keyframe<Value>] = []
        for keyframe in keyframes.enumerated().sorted(by: { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }).map(\.element) {
            if result.last?.time == keyframe.time { result.removeLast() }
            result.append(keyframe)
        }
        return result
    }
}

// MARK: - Frames

extension Timeline {
    /// Exact frame durations for the NTSC-family rates (23.976, 29.97, 59.94)
    /// rather than rounding them to 24/30/60. Other fractional rates, such
    /// as 12.5, are kept to a thousandth of a frame a second rather than
    /// rounded to a whole number.
    static func frameDuration(for frameRate: Double) -> CMTime {
        let clamped = min(max(frameRate, 1), 1000)
        let rounded = clamped.rounded()
        if abs(clamped - rounded * 1000 / 1001) < 0.01 {
            return CMTime(value: 1001, timescale: Int32(rounded) * 1000)
        }
        if abs(clamped - rounded) < 0.0005 {
            return CMTime(value: 1, timescale: Int32(rounded))
        }
        return CMTime(value: 1000, timescale: Int32((clamped * 1000).rounded()))
    }

    var frameDuration: CMTime { Self.frameDuration(for: frameRate) }

    /// The start of the frame nearest `time`, never before zero. Keyframes
    /// sit on frames so two edits at the same playhead hit the same keyframe.
    func snappedToFrame(_ time: CMTime) -> CMTime {
        CMTimeMaximum(.zero, frameAligned(time, .nearest))
    }
}
