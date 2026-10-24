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
            count: count.clamped(between: Self.countRange.lowerBound, and: Self.countRange.upperBound),
            delay: CMTimeMaximum(delay, CMTime(value: 1, timescale: 1000)),
            decay: decay.clamped(between: Self.decayRange.lowerBound, and: Self.decayRange.upperBound)
        )
    }
}

/// What a clip does to time, above its stack: which source frames the rest
/// of the clip receives.
struct ClipTime: Equatable, Sendable {
    /// A percentage, 100 playing at the source's own speed and negative
    /// playing it backwards. Keyframed in the clip's source time (see
    /// `TimelineClip.timelineTime(forSourceTime:)`). The first keyframe's
    /// sign (or the value's, with none) is the clip's direction; a speed
    /// can't turn around partway (that would take forever to play), so the
    /// other keyframes keep that direction, and no speed is under 1%.
    var speed = AnimatedValue(100.0)
    var frameBlending = FrameBlending.off
    var echo: Echo?
    var sound = SoundMode.keepPitch

    /// How fast a clip may play, in either direction.
    static let speedRange = 1.0...10_000.0

    /// `speed` held to `speedRange` in size, keeping its sign (zero counts
    /// as forwards).
    static func clampedSpeed(_ speed: Double) -> Double {
        let size = abs(speed).clamped(between: speedRange.lowerBound, and: speedRange.upperBound)
        return speed < 0 ? -size : size
    }

    /// Whether the speed plays the source backwards.
    var isReversed: Bool { Self.isReversed(speed) }

    /// Whether `speed` plays backwards: its first keyframe's sign, or its
    /// value's with none.
    static func isReversed(_ speed: AnimatedValue<Double>) -> Bool {
        (speed.keyframes.first?.value ?? speed.value) < 0
    }

    /// How fast a speed `value` plays in a clip going the way `reversed`
    /// says, as a size. A value eased past zero, or under 1% that way, is
    /// held at 1%: the clip can't turn around, and taking the value's size
    /// instead would play a dip to -50% as 50% forwards.
    static func playedSize(_ value: Double, reversed: Bool) -> Double {
        let along = reversed ? -value : value
        return along.clamped(between: speedRange.lowerBound, and: speedRange.upperBound)
    }

    /// The speed turned to play forwards or backwards, with its sizes,
    /// keyframes and eases as they were: 100% becomes -100%.
    mutating func setReversed(_ reversed: Bool) {
        let sign: Double = reversed ? -1 : 1
        speed = AnimatedValue(
            abs(speed.value) * sign,
            keyframes: speed.keyframes.map { $0.with(value: abs($0.value) * sign) }
        )
    }

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
            angle: angle.clamped(between: Self.angleRange.lowerBound, and: Self.angleRange.upperBound),
            samples: samples.clamped(between: Self.sampleRange.lowerBound, and: Self.sampleRange.upperBound)
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

    /// Whether the clip plays its source backwards: its leading edge on the
    /// timeline is the end of its trim.
    var isReversed: Bool { time.isReversed }

    /// How fast the clip plays at a moment of its source, as a percentage,
    /// negative when it plays backwards.
    func speed(atSource sourceTime: CMTime) -> Double {
        let reversed = isReversed
        let size = ClipTime.playedSize(time.speed.value(at: sourceTime), reversed: reversed)
        return reversed ? -size : size
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
        let speed = abs(speed(atSource: a))
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
        // Backwards, the clip starts at the end of its trim.
        CMTimeAdd(startOffset, isReversed ? timelineLength(ofSource: sourceTime, to: trimEnd) : timelineLength(ofSource: trimStart, to: sourceTime))
    }

    /// The moment of the source playing at `time` in the timeline.
    func sourceTime(atTimelineTime time: CMTime) -> CMTime {
        let elapsed = CMTimeSubtract(time, startOffset)
        let reversed = isReversed
        // Backwards, the source is run from the end of the trim toward its
        // start.
        let anchor = reversed ? trimEnd : trimStart
        guard self.time.speed.isAnimated else {
            let speed = abs(speed(atSource: trimStart))
            let moved: CMTime
            if speed == 100 {
                moved = elapsed
            } else if speed.rounded() == speed {
                moved = CMTimeMultiplyByRatio(elapsed, multiplier: Int32(speed), divisor: 100)
            } else {
                moved = CMTimeMultiplyByFloat64(elapsed, multiplier: speed / 100)
            }
            return reversed ? CMTimeSubtract(anchor, moved) : CMTimeAdd(anchor, moved)
        }
        // Playing the source takes more time the more of it has played, so
        // find where the time that has passed is used up.
        let integral = SpeedIntegral.of(self.time.speed)
        let passed = reversed ? -elapsed.seconds : elapsed.seconds
        return CMTime(seconds: integral.source(atIntegral: integral.at(anchor.seconds) + passed), preferredTimescale: 240_000)
    }

    /// How much source plays in `length` of timeline time from the clip's
    /// start (what trimming the end to that length leaves).
    func sourceDuration(forPlaced length: CMTime) -> CMTime {
        let end = sourceTime(atTimelineTime: CMTimeAdd(startOffset, length))
        return isReversed ? CMTimeSubtract(trimEnd, end) : CMTimeSubtract(end, trimStart)
    }

    /// The clip trimmed at its trailing edge to last `length` on the
    /// timeline: the end of the trim, or the start of it when backwards.
    func lasting(_ length: CMTime) -> TimelineClip {
        var clip = self
        let source = sourceDuration(forPlaced: length)
        if isReversed { clip.trimStart = CMTimeSubtract(trimEnd, source) } else { clip.trimEnd = CMTimeAdd(trimStart, source) }
        return clip
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
/// the integral is a line.
///
/// Between keyframes it is built once, by adaptive Gauss-Kronrod (a 15-point
/// rule, with the 7-point Gauss rule inside it as its error estimate): a
/// piece is split until each cell's estimate is within its share of
/// `pieceTolerance`. The edges of the cells and the integral up to each are
/// kept, so a query finds its cell by binary search and integrates only the
/// part of that cell before it, and the inverse (`source(atIntegral:)`)
/// brackets the cell by the totals and solves inside it.
///
/// Accuracy budget, in seconds of timeline time:
///  - the curve is read at exact `Double` times (`value(atSeconds:)`), so
///    no time is cut to a grid;
///  - a piece's cells add up to within `pieceTolerance` (1e-8) of the true
///    integral, as far as the error estimate is true, and the part of a
///    cell a query adds is within another `pieceTolerance`. So `at(s)` is
///    within `(pieces before s + 2) * pieceTolerance` (one less at a
///    keyframe), plus about 1e-13 of the value for rounding;
///  - the inverse lands within `timeTolerance` (1e-9) of the target on
///    `at`'s own curve, so the round trip adds that, scaled by the speed.
/// All of it is small against the 1/240000 s the result is rounded to
/// (4e-6), which is the limit on a placed time.
struct SpeedIntegral {
    private let speed: AnimatedValue<Double>
    /// Cell edges, ascending: every keyframe time, and between them the
    /// points where a piece was split.
    private let edges: [Double]
    /// The integral at each edge.
    private let totals: [Double]

    /// What a piece's cells may be off by in total, and a query's partial
    /// cell too.
    static let pieceTolerance = 1e-8
    /// How far the inverse may land from the target, in timeline seconds.
    static let timeTolerance = 1e-9

    /// A cell is split to at most this many halvings.
    private static let maxDepth = 48

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

    /// Builds the cells; use `of` unless the cache is in the way.
    init(_ speed: AnimatedValue<Double>) {
        self.speed = speed
        let times = speed.keyframes.map(\.time.seconds)
        guard let first = times.first else {
            edges = []
            totals = []
            return
        }
        var edges = [first], totals = [0.0]
        for (a, b) in zip(times, times.dropFirst()) where b > a {
            var cells = [(end: Double, value: Double)]()
            Self.split(speed, a, b, tolerance: Self.pieceTolerance, depth: 0, into: &cells)
            for cell in cells {
                edges.append(cell.end)
                totals.append(totals[totals.count - 1] + cell.value)
            }
        }
        self.edges = edges
        self.totals = totals
    }

    /// The cell edges, for tests.
    var cellEdges: [Double] { edges }

    private static func rate(_ speed: AnimatedValue<Double>, at seconds: Double) -> Double {
        // Sizes only, along the clip's direction (see `playedSize`).
        return 100 / ClipTime.playedSize(speed.value(atSeconds: seconds), reversed: ClipTime.isReversed(speed))
    }

    private static let kronrodNodes = [0.991455371120813, 0.949107912342759, 0.864864423359769, 0.741531185599394, 0.586087235467691, 0.405845151377397, 0.207784955007898, 0.0]
    private static let kronrodWeights = [0.022935322010529, 0.063092092629979, 0.104790010322250, 0.140653259715525, 0.169004726639267, 0.190350578064785, 0.204432940075298, 0.209482141084728]
    private static let gaussWeights = [0.129484966168870, 0.279705391489277, 0.381830050505119, 0.417959183673469]

    /// The 15-point Kronrod estimate of the integral over `a...b` and the
    /// distance to the 7-point Gauss one, which says how far to trust it.
    private static func kronrod(_ speed: AnimatedValue<Double>, _ a: Double, _ b: Double) -> (value: Double, error: Double) {
        let centre = (a + b) / 2, half = (b - a) / 2
        var kronrodSum = 0.0, gaussSum = 0.0
        for index in 0..<8 {
            let node = kronrodNodes[index]
            let sum = index == 7
                ? rate(speed, at: centre)
                : rate(speed, at: centre - half * node) + rate(speed, at: centre + half * node)
            kronrodSum += kronrodWeights[index] * sum
            if index % 2 == 1 { gaussSum += gaussWeights[index / 2] * sum }
        }
        return (kronrodSum * half, abs(kronrodSum - gaussSum) * half)
    }

    /// Whether an estimate is within `tolerance`, or as close as rounding lets
    /// it get (so a tolerance halved many times can't ask for the impossible).
    private static func settled(_ estimate: (value: Double, error: Double), tolerance: Double, depth: Int) -> Bool {
        estimate.error <= max(tolerance, 64 * Double.ulpOfOne * abs(estimate.value)) || depth >= maxDepth
    }

    /// Splits `a...b` until each cell is settled, appending each with the
    /// integral over it. A cell's share of the tolerance is halved with each
    /// split, so the shares add up to the tolerance.
    private static func split(_ speed: AnimatedValue<Double>, _ a: Double, _ b: Double, tolerance: Double, depth: Int, into cells: inout [(end: Double, value: Double)]) {
        let estimate = kronrod(speed, a, b)
        if settled(estimate, tolerance: tolerance, depth: depth) {
            cells.append((b, estimate.value))
            return
        }
        let middle = (a + b) / 2
        split(speed, a, middle, tolerance: tolerance / 2, depth: depth + 1, into: &cells)
        split(speed, middle, b, tolerance: tolerance / 2, depth: depth + 1, into: &cells)
    }

    /// The integral over `a...b`, split as far as it needs to be.
    private static func integrate(_ speed: AnimatedValue<Double>, _ a: Double, _ b: Double, tolerance: Double, depth: Int = 0) -> Double {
        guard b > a else { return 0 }
        let estimate = kronrod(speed, a, b)
        if settled(estimate, tolerance: tolerance, depth: depth) { return estimate.value }
        let middle = (a + b) / 2
        return integrate(speed, a, middle, tolerance: tolerance / 2, depth: depth + 1)
            + integrate(speed, middle, b, tolerance: tolerance / 2, depth: depth + 1)
    }

    /// The cell `seconds` is in: the last edge at or before it.
    private func cell(containing seconds: Double) -> Int {
        var low = 0, high = edges.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if edges[middle] <= seconds { low = middle } else { high = middle }
        }
        return low
    }

    /// The integral at `seconds` of source time.
    func at(_ seconds: Double) -> Double {
        guard let first = edges.first, let last = edges.last else { return seconds * Self.rate(speed, at: 0) }
        if seconds <= first { return (seconds - first) * Self.rate(speed, at: first) }
        if seconds >= last { return totals[totals.count - 1] + (seconds - last) * Self.rate(speed, at: last) }
        let index = cell(containing: seconds)
        return totals[index] + Self.integrate(speed, edges[index], seconds, tolerance: Self.pieceTolerance)
    }

    /// The source time, in seconds, whose integral is `target`: the inverse
    /// of `at`. The rate is always positive, so `at` only rises and the
    /// answer is the only one. The totals say which cell it is in; there it
    /// is found by Newton's method, whose step is the timeline time left over
    /// divided by the rate. A step that leaves the bracket the cell and
    /// earlier steps have narrowed, or that fails to halve the error, is
    /// replaced by bisection, so it always ends.
    func source(atIntegral target: Double) -> Double {
        guard let first = edges.first, let last = edges.last else { return target / Self.rate(speed, at: 0) }
        if target <= 0 { return first + target / Self.rate(speed, at: first) }
        let end = totals[totals.count - 1]
        if target >= end { return last + (target - end) / Self.rate(speed, at: last) }
        // The last edge whose total is at or below the target.
        var low = 0, high = totals.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if totals[middle] <= target { low = middle } else { high = middle }
        }
        if totals[low] == target { return edges[low] }
        let remaining = target - totals[low]
        var lower = edges[low], upper = edges[low + 1]
        var guess = lower + (upper - lower) * remaining / (totals[low + 1] - totals[low])
        var lastError = Double.infinity
        for _ in 0..<100 {
            let error = Self.integrate(speed, edges[low], guess, tolerance: Self.pieceTolerance) - remaining
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
              var clip = timeline.layer(id: layerID)?.clips.first(id: clipID)
        else {
            return
        }
        var settings = clip.time
        change(&settings)
        // Every keyframe goes the way the first does.
        let direction: Double = settings.isReversed ? -1 : 1
        settings.speed = AnimatedValue(
            Self.clampedSpeed(settings.speed.value, direction: direction),
            keyframes: settings.speed.keyframes.map {
                $0.with(value: Self.clampedSpeed($0.value, direction: direction))
            }
        )
        settings.echo = settings.echo?.clamped
        guard settings != clip.time else { return }
        clip.time = settings
        applyRipple(coveringWholeFrames(clip, in: timeline), in: timelineID, layer: layerID)
    }

    private static func clampedSpeed(_ speed: Double, direction: Double) -> Double {
        abs(ClipTime.clampedSpeed(speed)) * direction
    }
}
