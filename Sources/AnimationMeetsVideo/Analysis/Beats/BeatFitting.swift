import Accelerate
import CoreMedia
import Foundation

/// An onset curve (see `OnsetAnalyzer`) prepared for fitting beats to: what
/// stands out from the surrounding second, scaled to unit spread, so never
/// negative. Frame positions are in the asset's original time, the time of
/// a beat map.
struct OnsetCurve: Sendable, Equatable {
    var values: [Float] { didSet { cache = Cache() } }
    var framesPerSecond: Double { didSet { cache = Cache() } }
    /// The original time, in seconds, of frame 0's center.
    var start: Double
    /// What is worked out from the values once and read many times. Copies
    /// share it, a shifted one (`BeatFitting.aligned`) too, since it
    /// depends on the values and frame rate alone.
    private var cache = Cache()

    init(values: [Float], framesPerSecond: Double, start: Double) {
        self.values = values
        self.framesPerSecond = framesPerSecond
        self.start = start
    }

    static func == (a: OnsetCurve, b: OnsetCurve) -> Bool {
        a.start == b.start && a.framesPerSecond == b.framesPerSecond && a.values == b.values
    }

    func frame(atSeconds seconds: Double) -> Double { (seconds - start) * framesPerSecond }
    func seconds(atFrame frame: Double) -> Double { start + frame / framesPerSecond }

    func value(at frame: Int) -> Float {
        frame >= 0 && frame < values.count ? values[frame] : 0
    }

    /// The curve between frames, linearly.
    func interpolatedValue(atFrame frame: Double) -> Float {
        let low = Self.index(frame.rounded(.down)), share = Float(frame - Double(low))
        return value(at: low) * (1 - share) + value(at: low + 1) * share
    }

    /// The strongest onset within `reach` frames of `frame`, and where it
    /// is, refined between frames by fitting a parabola through the peak.
    func peak(near frame: Double, reach: Double) -> (frame: Double, strength: Float) {
        let low = Self.index((frame - reach).rounded(.down)), high = Self.index((frame + reach).rounded(.up))
        var best = Self.index(frame.rounded()), strength = value(at: best)
        // Frames past the ends are 0, which never beats a value.
        let first = max(low, 0), last = min(high, values.count - 1)
        if first <= last {
            values.withUnsafeBufferPointer { values in
                for candidate in first...last where values[candidate] > strength {
                    best = candidate
                    strength = values[candidate]
                }
            }
        }
        return (Double(best) + subframeOffset(at: best), strength)
    }

    /// As strong as `peak(near:reach:)`, without where: two reads of the
    /// curve dilated to cover the frames it would scan.
    func strength(near frame: Double, reach: Double) -> Float {
        let low = Self.index((frame - reach).rounded(.down)), high = Self.index((frame + reach).rounded(.up))
        // The span is at least 2 × reach rounded up, so two windows of
        // half that, one from each end, cover it and stay inside it.
        let window = max(0, Int((2 * reach).rounded(.up)) / 2)
        let dilated = localMax(window: window)
        return max(dilated.value(at: low + window), dilated.value(at: high - window))
    }

    /// Where between frames the peak at `frame` really is, from the
    /// parabola through it and its neighbours; 0 unless it is a peak.
    func subframeOffset(at frame: Int) -> Double {
        let left = Double(value(at: frame - 1)), middle = Double(value(at: frame)), right = Double(value(at: frame + 1))
        let curve = left - 2 * middle + right
        guard middle >= left, middle >= right, curve < 0 else { return 0 }
        return (0.5 * (left - right) / curve).clamped(between: -0.5, and: 0.5)
    }

    /// The curve dilated by `window`: at each frame, the largest value
    /// within `window` frames of it. Built once per window and kept.
    func localMax(window: Int) -> LocalMaximum {
        cache.localMax(window: max(0, window)) { window in
            // Padded with zeros, which frames past the ends are, so the
            // dilation reaches `window` frames past each end too.
            var padded = [Float](repeating: 0, count: values.count + 4 * window)
            padded.replaceSubrange((2 * window)..<(2 * window + values.count), with: values)
            var dilated = [Float](repeating: 0, count: values.count + 2 * window)
            if !dilated.isEmpty {
                vDSP_vswmax(padded, 1, &dilated, 1, vDSP_Length(dilated.count), vDSP_Length(2 * window + 1))
            }
            return LocalMaximum(window: window, values: dilated)
        }
    }

    /// See `localMax(window:)`.
    struct LocalMaximum: Sendable {
        var window: Int
        /// From `window` frames before the curve to `window` past it.
        var values: [Float]

        func value(at frame: Int) -> Float {
            let index = frame + window
            return index >= 0 && index < values.count ? values[index] : 0
        }
    }

    /// The period `BeatFitting.estimatedPeriod` found between two frames,
    /// worked out by `compute` the first time.
    func memoizedPeriod(first: Int, last: Int, _ compute: () throws -> Double?) rethrows -> Double? {
        try cache.period(key: [first, last], compute)
    }

    /// A frame as an index, kept to a range that converts: a time far off
    /// the curve, or not a number, reads as past its end.
    static func index(_ frame: Double) -> Int {
        guard !frame.isNaN else { return Int.min / 4 }
        return Int(frame.clamped(between: -1e15, and: 1e15))
    }

    /// See `cache`. Locked, since the curve is handed to fills off the main
    /// thread, and each build is short.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var dilated: [Int: LocalMaximum] = [:]
        private var periods: [[Int]: Double?] = [:]

        func localMax(window: Int, _ build: (Int) -> LocalMaximum) -> LocalMaximum {
            lock.lock()
            defer { lock.unlock() }
            if let found = dilated[window] { return found }
            let built = build(window)
            dilated[window] = built
            return built
        }

        func period(key: [Int], _ compute: () throws -> Double?) rethrows -> Double? {
            lock.lock()
            if let found = periods[key] {
                lock.unlock()
                return found
            }
            lock.unlock()
            // Worked out unlocked: it is the long part, and can be cancelled.
            let period = try compute()
            lock.lock()
            periods[key] = period
            lock.unlock()
            return period
        }
    }
}

/// Fills the sections of a beat map from the beats the person pinned: see
/// docs/beat-matching.md. Everything works in seconds of original time on
/// an `OnsetCurve`, and is a pure function of its inputs. The long searches
/// stop with `CancellationError` when their task is cancelled.
enum BeatFitting {
    enum Failure: LocalizedError, Equatable {
        /// A consistent section is filled from two anchors.
        case needsTwoAnchors
        /// A ramp needs a filled section, or a marked measure, at each end.
        case needsBothEnds
        /// Only consistent sections and ramps have beats.
        case notAnalyzed
        /// The pinned beats and the onsets gave no tempo to step at.
        case unusableTempo
        /// A consistent section shorter than two beats at its tempo.
        case tooShort

        var errorDescription: String? {
            switch self {
            case .needsTwoAnchors: "Place two anchor beats first."
            case .needsBothEnds: "A ramp needs a filled section on each side, or every beat of one measure marked at an end without one."
            case .notAnalyzed: "This section isn't analyzed."
            case .unusableTempo: "Couldn't find a tempo here."
            case .tooShort: "This section is shorter than two beats."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .needsTwoAnchors: "Drop one near the middle of the section and a second near its far end (M)."
            case .needsBothEnds: "Fill the sections either side first, or press M on every beat of one measure at each open end."
            case .notAnalyzed: "Make it a consistent section or a ramp to fill it."
            case .unusableTempo: "Try pinning two beats farther apart."
            case .tooShort: "Drag an edge to make it longer, or type a faster tempo."
            }
        }
    }

    /// What a fill found and did, for the panel to tell the person.
    struct FillReport: Equatable, Sendable {
        /// The period the beats step at, in seconds; nil for a ramp, whose
        /// period moves.
        var period: Double?
        var beatsPerMinute: Double? { period.map { 60 / $0 } }
        /// The number of beats between the two anchors farthest apart, when
        /// it was searched for (a first fill without a typed tempo).
        var anchorCount: Int?
        /// Whether the anchors' places in the measure settled that count
        /// over one that landed on stronger onsets.
        var measureOverruledOnsets = false
        /// The section's beats after the fill.
        var beatCount = 0
        /// Beats with no clear onset to snap onto, left on the grid.
        var quietBeats = 0
        /// Beats stepping past the music that were dropped as silence.
        var droppedSilentBeats = 0
        /// What moving the section's edges onto its beats did.
        var edges = EdgeSnap.unchanged
    }

    enum EdgeSnap: Equatable, Sendable {
        /// The fill didn't move them: a refill, or a ramp.
        case unchanged
        /// They moved onto the first beat and the one after the last.
        case moved
        /// The beats left no room between the edges, so they stayed.
        case tooShort
    }

    /// How strongly beats keep to the expected gap while chasing onsets; the
    /// tracker's, since the curve is scaled the same way.
    static let tightness = BeatTracker.tightness
    /// How far a refined beat may move, as a share of the gap: stepping on
    /// from the beat before, which follows drift as it goes, and in a chain
    /// held between two anchors, where drift adds up away from an even grid.
    static let steadyReach = 0.15
    static let chainReach = 0.25
    static let rampReach = 0.25
    /// The most frames a chained beat is searched either side of its even
    /// place, which bounds the chain's work on fine curves: past a quarter
    /// of a beat at 60 BPM on the panel's curve, so it limits only slower
    /// tempos there.
    static let chainReachFrames = 96
    /// How far, as a share of the expected count, the number of beats
    /// between two anchors is searched.
    static let countSearch = 0.12
    /// A count that keeps the anchors' places in the measure is taken if its
    /// grid scores at least this share of the best grid's.
    static let measureHint = 0.8
    /// What straying from an even ramp's count costs, per squared log of
    /// the ratio: a tenth of the tightness, since a ramp's gaps aren't
    /// held to an even change of tempo.
    static let rampCountWeight = tightness / 10
    /// An onset weaker than this (the curve's RMS is 1) doesn't pull a beat
    /// that steps on past the anchors: through a quiet stretch the beats
    /// keep the tempo instead.
    static let weakOnset: Float = 0.5

    // MARK: Whole map

    /// Fills one section of `map`, keeping every pinned beat where it is,
    /// then numbers every beat's place in the measure across the song.
    /// `tempo`, in beats per minute, overrides the tempo found for a
    /// consistent section. Beats are rounded to samples at `sampleRate`.
    ///
    /// A consistent section's edges then move to its first beat and to
    /// where the beat after its last would fall, and a neighbour that
    /// touched an edge moves with it, so sections meet on a beat.
    static func fill(
        _ map: BeatMap, section id: UUID, curve: OnsetCurve, sampleRate: Double, duration: CMTime, tempo: Double? = nil
    ) throws -> BeatMap {
        try fillReporting(map, section: id, curve: curve, sampleRate: sampleRate, duration: duration, tempo: tempo).map
    }

    /// `fill`, with what it found and did.
    static func fillReporting(
        _ map: BeatMap, section id: UUID, curve: OnsetCurve, sampleRate: Double, duration: CMTime, tempo: Double? = nil
    ) throws -> (map: BeatMap, report: FillReport) {
        guard let index = map.sections.firstIndex(id: id) else { return (map, FillReport()) }
        var map = map
        let section = map.sections[index]
        var report: FillReport
        switch section.kind {
        case .consistent:
            let filled = try consistentFill(section, curve: curve, sampleRate: sampleRate, tempo: tempo)
            map.sections[index] = filled.section
            report = filled.report
            // Only the first fill moves the edges: after that they are where
            // the person left them.
            if !section.isConfirmed, let period = report.period {
                report.edges = snapEdges(of: index, in: &map, period: period, sampleRate: sampleRate, duration: duration)
            }
        case .ramp:
            let filled = try rampFill(
                section, before: neighbour(of: index, in: map, step: -1), after: neighbour(of: index, in: map, step: 1),
                curve: curve, sampleRate: sampleRate
            )
            map.sections[index] = filled.section
            report = filled.report
        case .none:
            throw Failure.notAnalyzed
        }
        map.recountPositions()
        return (map, report)
    }

    /// The filled section touching the one at `index` on one side, whose
    /// beats a ramp continues from.
    private static func neighbour(of index: Int, in map: BeatMap, step: Int) -> BeatSection? {
        let other = index + step
        guard map.sections.indices.contains(other) else { return nil }
        let section = map.sections[index], candidate = map.sections[other]
        let gap = step < 0 ? CMTimeSubtract(section.start, candidate.end) : CMTimeSubtract(candidate.start, section.end)
        guard candidate.kind != .none, candidate.isConfirmed, candidate.beats.count >= 2,
              abs(gap.seconds) < touchTolerance
        else { return nil }
        return candidate
    }

    /// Edges closer than this, in seconds, touch.
    static let touchTolerance = 0.05

    /// Moves the edges of the section at `index` onto its beats; see `fill`.
    @discardableResult
    static func snapEdges(of index: Int, in map: inout BeatMap, period: Double, sampleRate: Double, duration: CMTime) -> EdgeSnap {
        let section = map.sections[index]
        guard let first = section.beats.first, let last = section.beats.last else { return .tooShort }
        // A neighbour that touches moves with the edge, as far as its own
        // other edge; one that doesn't stays where it is.
        func touches(_ a: CMTime, _ b: CMTime) -> Bool { abs(CMTimeSubtract(a, b).seconds) < touchTolerance }
        let lowest: CMTime
        if index > 0 {
            let previous = map.sections[index - 1]
            lowest = touches(previous.end, section.start) ? previous.start : previous.end
        } else {
            lowest = .zero
        }
        let highest: CMTime
        if index + 1 < map.sections.count {
            let next = map.sections[index + 1]
            highest = touches(next.start, section.end) ? next.end : next.start
        } else {
            highest = duration
        }
        let after = time(last.time.seconds + period, sampleRate: sampleRate)
        guard after.isNumeric else { return .tooShort }
        let start = CMTimeMaximum(first.time, lowest)
        let end = CMTimeMinimum(after, highest)
        guard CMTimeCompare(start, end) < 0 else { return .tooShort }
        if index > 0, touches(map.sections[index - 1].end, section.start), CMTimeCompare(map.sections[index - 1].start, start) < 0 {
            map.sections[index - 1].end = start
        }
        if index + 1 < map.sections.count, touches(map.sections[index + 1].start, section.end),
           CMTimeCompare(end, map.sections[index + 1].end) < 0 {
            map.sections[index + 1].start = end
        }
        map.sections[index].start = start
        map.sections[index].end = end
        return CMTimeCompare(start, section.start) != 0 || CMTimeCompare(end, section.end) != 0 ? .moved : .unchanged
    }

    /// A section's pinned beats in time order, with only one of any that
    /// fall on the same sample: two at one time would make a gap of
    /// nothing, and so a period of nothing.
    static func distinctPins(of section: BeatSection, sampleRate: Double) -> [MappedBeat] {
        let sample = 1 / max(1, sampleRate)
        var pins: [MappedBeat] = []
        for beat in section.pinnedBeats.filter({ $0.time.isNumeric }).sorted(by: { CMTimeCompare($0.time, $1.time) < 0 }) {
            if let last = pins.last, beat.time.seconds - last.time.seconds < sample { continue }
            pins.append(beat)
        }
        return pins
    }

    /// Whether `period`, in seconds, is one beats can step at.
    private static func usable(_ period: Double) -> Bool { period.isFinite && period > 1e-4 }

    // MARK: Consistent sections

    /// Fills a consistent section from its pinned beats (at least two, or
    /// one with a `tempo`, as when a tempo is pasted from another section),
    /// and gives the period it settled on, in seconds.
    ///
    /// The tempo comes from `tempo`, else from the beats already there when
    /// the section is being reanalyzed, else from the onsets. Between two
    /// pinned beats the count is the nearest whole number of periods; for
    /// the first fill, the count between the two anchors is searched near
    /// that, preferring counts that keep the anchors' places in the measure
    /// and then the grid that lands on the strongest onsets.
    static func fillConsistent(
        _ section: BeatSection, curve: OnsetCurve, sampleRate: Double, tempo: Double? = nil
    ) throws -> (section: BeatSection, period: Double) {
        let filled = try consistentFill(section, curve: curve, sampleRate: sampleRate, tempo: tempo)
        return (filled.section, filled.report.period ?? 0)
    }

    private static func consistentFill(
        _ section: BeatSection, curve: OnsetCurve, sampleRate: Double, tempo: Double?
    ) throws -> (section: BeatSection, report: FillReport) {
        let typed = tempo.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        let distinct = distinctPins(of: section, sampleRate: sampleRate)
        guard distinct.count >= 2 || (typed != nil && !distinct.isEmpty) else { throw Failure.needsTwoAnchors }
        var report = FillReport()
        let curve = aligned(curve, to: distinct.map(\.time.seconds))
        // Beats placed by ear are a few milliseconds off; each moves onto
        // its onset, and stays pinned.
        let pins = snapped(distinct, curve: curve, sampleRate: sampleRate)
        let pinTimes = pins.map(\.time.seconds)
        guard let firstPin = pinTimes.first, let lastPin = pinTimes.last else { throw Failure.needsTwoAnchors }
        let start = section.start.seconds, end = section.end.seconds
        let reanalyzing = section.isConfirmed && section.beats.count > pins.count

        var period: Double
        var counts: [Int]
        let gaps = zip(pinTimes, pinTimes.dropFirst()).map { $1 - $0 }
        if let typed {
            period = 60 / typed
            guard usable(period) else { throw Failure.unusableTempo }
            counts = gaps.map { max(1, Int(($0 / period).rounded())) }
        } else if reanalyzing, let typical = medianGap(of: section.beats.map(\.time.seconds)) {
            period = typical
            guard usable(period) else { throw Failure.unusableTempo }
            counts = gaps.map { max(1, Int(($0 / period).rounded())) }
        } else {
            // Without a typed tempo there are two pins, so a gap.
            guard let widest = gaps.indices.max(by: { gaps[$0] < gaps[$1] }) else { throw Failure.needsTwoAnchors }
            let estimate = try estimatedPeriod(curve: curve, from: max(start, firstPin - 4), to: min(end, lastPin + 4))
                ?? gaps[widest] / max(1, (gaps[widest] / 0.5).rounded())
            guard usable(estimate) else { throw Failure.unusableTempo }
            // The widest pair decides the tempo; the rest round to it.
            let choice = try countChoice(
                from: pinTimes[widest], to: pinTimes[widest + 1], period: estimate, curve: curve,
                positions: (pins[widest].position, pins[widest + 1].position), beatsPerMeasure: section.beatsPerMeasure,
                refined: section.steadiness == .intent
            )
            report.anchorCount = choice.count
            report.measureOverruledOnsets = choice.overruled
            period = gaps[widest] / Double(choice.count)
            guard usable(period) else { throw Failure.unusableTempo }
            counts = gaps.map { max(1, Int(($0 / period).rounded())) }
            counts[widest] = choice.count
        }
        // What the pinned beats say the tempo is, all of them counted.
        if !gaps.isEmpty { period = zip(gaps, counts).map { $0 / Double($1) }.sorted()[gaps.count / 2] }
        // Close anchors give only a rough tempo; the whole section's onsets
        // pin it down.
        if typed == nil, !reanalyzing {
            period = try fittedPeriod(near: period, pins: pinTimes, from: start, to: end, curve: curve)
        }
        guard usable(period) else { throw Failure.unusableTempo }
        guard end - start >= 2 * period else { throw Failure.tooShort }

        let refine = section.steadiness == .intent
        var times: [Double] = []
        let before = steps(from: firstPin, period: period, direction: -1, limit: start, curve: curve, refine: refine)
        times += before.times.reversed()
        var scratch = ChainScratch()
        for (index, gap) in gaps.enumerated() {
            let a = pinTimes[index], b = pinTimes[index + 1], count = counts[index]
            let ideal = (1..<count).map { a + gap * Double($0) / Double(count) }
            times += refine ? try chain(from: a, to: b, ideal: ideal, curve: curve, reach: chainReach, scratch: &scratch).times : ideal
        }
        let after = steps(from: lastPin, period: period, direction: 1, limit: end, curve: curve, refine: refine)
        times += after.times
        report.droppedSilentBeats = before.dropped + after.dropped

        var quiet = 0
        var filled = section
        filled.beats = pins + snapped(
            times.filter { $0.isFinite && $0 >= start && $0 < end }.map { MappedBeat(time: time($0, sampleRate: sampleRate)) },
            curve: curve, sampleRate: sampleRate, quiet: &quiet
        )
        filled.isConfirmed = true
        filled.normalize()
        report.period = period
        report.beatCount = filled.beats.count
        report.quietBeats = quiet
        return (filled, report)
    }

    /// The longest stretch, in seconds, `estimatedPeriod` reads: a tempo
    /// stands out of a minute of music as well as of a whole song.
    static let estimationWindow = 60.0

    /// The beat period, in seconds, that the onsets between two times
    /// repeat at most, weighted toward everyday tempos the way detection
    /// is; nil with too little to tell. Past `estimationWindow`, only that
    /// much from the middle of the stretch is read.
    static func estimatedPeriod(curve: OnsetCurve, from: Double, to: Double) throws -> Double? {
        let rate = curve.framesPerSecond
        guard rate.isFinite, rate > 0 else { return nil }
        var first = max(0, OnsetCurve.index(curve.frame(atSeconds: from)))
        var last = min(curve.values.count, OnsetCurve.index(curve.frame(atSeconds: to)))
        let widest = Int(estimationWindow * rate)
        if last - first > widest {
            first += (last - first - widest) / 2
            last = first + widest
        }
        let shortest = max(2, Int((rate * 60 / BeatTracker.maximumBPM).rounded(.down)))
        let longest = Int((rate * 60 / BeatTracker.minimumBPM).rounded(.up))
        guard last - first > 2 * longest else { return nil }
        let preferred = rate * 60 / BeatTracker.preferredBPM
        let (low, high) = (first, last)
        return try curve.memoizedPeriod(first: low, last: high) {
            var scores: [Double] = []
            scores.reserveCapacity(longest - shortest + 1)
            try curve.values.withUnsafeBufferPointer { values in
                guard let base = values.baseAddress else { return }
                for lag in shortest...longest {
                    if (lag - shortest) % 64 == 0, Task.isCancelled { throw CancellationError() }
                    let count = high - lag - low
                    var sum: Float = 0
                    vDSP_dotpr(base + low, 1, base + low + lag, 1, &sum, vDSP_Length(count))
                    let octaves = log2(Double(lag) / preferred) / 1.4
                    scores.append(Double(sum) / Double(count) * exp(-0.5 * octaves * octaves))
                }
            }
            guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { return nil }
            var lag = Double(shortest + best)
            if best > 0, best + 1 < scores.count {
                let left = scores[best - 1], middle = scores[best], right = scores[best + 1]
                let bend = left - 2 * middle + right
                if bend < 0 { lag += (0.5 * (left - right) / bend).clamped(between: -0.5, and: 0.5) }
            }
            return lag / rate
        }
    }

    /// The tempo, in beats per minute, the onsets around a lone pinned beat
    /// suggest: what the panel shows before the second anchor is placed.
    static func provisionalTempo(around pin: Double, in section: BeatSection, curve: OnsetCurve) throws -> Double? {
        let from = max(section.start.seconds, pin - provisionalReach), to = min(section.end.seconds, pin + provisionalReach)
        guard let period = try estimatedPeriod(curve: curve, from: from, to: to), usable(period) else { return nil }
        return 60 / period
    }

    /// How far either side of a lone anchor `provisionalTempo` listens.
    static let provisionalReach = 6.0

    /// How many beat periods lie between two anchors: near the gap over
    /// `period`, keeping the anchors' places in the measure, and among
    /// those the one that lands on the strongest onsets. That is an even
    /// grid for a section produced to a click, and the refined chain for
    /// one steady by intent, whose drift takes an even grid off the beats.
    ///
    /// Anchors given different places are the person's word, so the count
    /// must keep them. Two downbeats (both left at 1) may just not have been
    /// numbered, so that is a strong hint the onsets can overrule.
    static func beatCount(
        from a: Double, to b: Double, period: Double, curve: OnsetCurve,
        positions: (Int, Int), beatsPerMeasure: Int, refined: Bool = false
    ) throws -> Int {
        try countChoice(from: a, to: b, period: period, curve: curve, positions: positions, beatsPerMeasure: beatsPerMeasure, refined: refined).count
    }

    /// `beatCount`, and whether the measure chose it over a count that
    /// landed on stronger onsets.
    private static func countChoice(
        from a: Double, to b: Double, period: Double, curve: OnsetCurve,
        positions: (Int, Int), beatsPerMeasure: Int, refined: Bool
    ) throws -> (count: Int, overruled: Bool) {
        let expected = (b - a) / period
        guard expected.isFinite, expected > 0 else { throw Failure.unusableTempo }
        let low = max(1, Int((expected * (1 - countSearch)).rounded(.down)))
        let high = max(low, Int((expected * (1 + countSearch)).rounded(.up)))
        var scratch = ChainScratch()
        let scored = try (low...high).map { count -> (count: Int, score: Double) in
            if Task.isCancelled { throw CancellationError() }
            guard refined else { return (count, gridScore(from: a, to: b, count: count, curve: curve)) }
            let ideal = (1..<count).map { a + (b - a) * Double($0) / Double(count) }
            return (count, try chain(from: a, to: b, ideal: ideal, curve: curve, reach: chainReach, scratch: &scratch).score)
        }
        guard let best = scored.max(by: { $0.score < $1.score }) else { throw Failure.unusableTempo }
        // The measure is a strong hint, not a rule: anchors given the wrong
        // places shouldn't force a count the onsets plainly disagree with.
        let measured = scored.filter { ($0.count - (positions.1 - positions.0)).modulo(max(1, beatsPerMeasure)) == 0 }
        if positions.0 != positions.1, let fitting = measured.max(by: { $0.score < $1.score }) {
            return (fitting.count, fitting.count != best.count)
        }
        guard let fitting = measured.max(by: { $0.score < $1.score }),
              fitting.score >= best.score - (1 - measureHint) * abs(best.score)
        else {
            return (best.count, false)
        }
        return (fitting.count, fitting.count != best.count)
    }

    /// The mean onset under an even grid of `count` steps from `a` to `b`,
    /// carried on `gridOverhang` steps past each, each taken within a few
    /// milliseconds of its place. The anchors themselves are left out: they
    /// sit on onsets whatever the count, which made two close anchors look
    /// best with nothing between them.
    static func gridScore(from a: Double, to b: Double, count: Int, curve: OnsetCurve) -> Double {
        let step = (b - a) / Double(count)
        var total = 0.0, points = 0
        for index in -gridOverhang...(count + gridOverhang) where index != 0 && index != count {
            total += strength(at: a + step * Double(index), curve: curve)
            points += 1
        }
        return points > 0 ? total / Double(points) : 0
    }

    /// See `gridScore`: two measures of four.
    static let gridOverhang = 8

    /// How far, in frames, `strength(at:curve:)` looks either side.
    private static func strengthReach(_ curve: OnsetCurve) -> Double { max(1, 0.006 * curve.framesPerSecond) }

    /// The onset within a few milliseconds of a time.
    private static func strength(at seconds: Double, curve: OnsetCurve) -> Double {
        Double(curve.strength(near: curve.frame(atSeconds: seconds), reach: strengthReach(curve)))
    }

    /// How far, in seconds, an anchor placed by ear may be off the beat.
    static let anchorUncertainty = 0.005

    /// The period whose grid, stepping out from the outermost pinned beats
    /// to the section's edges, lands on the strongest onsets: searched near
    /// `period`, as far as the anchors' own uncertainty over their span
    /// allows. Anchors a beat or two apart give a period a millisecond or
    /// so off, which adds up to a beat by the end of a song; across the
    /// whole section the onsets settle it to a fraction of that.
    static func fittedPeriod(near period: Double, pins: [Double], from start: Double, to end: Double, curve: OnsetCurve) throws -> Double {
        guard let first = pins.first, let last = pins.last, usable(period), start.isFinite, end.isFinite else { return period }
        let span = max(last - first, period)
        let reach = period * (2 * anchorUncertainty / span).clamped(between: 0.0005, and: 0.03)
        // Fine enough that the farthest beat moves under a millisecond a step.
        let farthest = max((first - start) / period, (end - last) / period, 1)
        let step = 0.001 / farthest
        let steps = min(4000, max(1, Int((reach / step).rounded(.up))))
        func candidate(_ index: Int) -> Double { period + reach * Double(index) / Double(steps) }
        let strengthReach = strengthReach(curve)

        /// How many beats of a grid at `candidate` lie before the first
        /// pinned beat, and after the last, inside the section.
        func beats(_ candidate: Double) -> (before: Int, after: Int) {
            var before = 0, after = 0
            while first - Double(before + 1) * candidate >= start { before += 1 }
            while last + Double(after + 1) * candidate < end { after += 1 }
            return (before, after)
        }
        /// The mean onset within a few milliseconds of each beat of the
        /// grid, its beats placed by multiplying, so steps don't add up
        /// rounding.
        func score(_ candidate: Double) -> Double {
            var total = 0.0, points = 0
            var k = 1.0
            while first - k * candidate >= start {
                total += strength(at: first - k * candidate, curve: curve)
                points += 1
                k += 1
            }
            k = 1
            while last + k * candidate < end {
                total += strength(at: last + k * candidate, curve: curve)
                points += 1
                k += 1
            }
            return points > 0 ? total / Double(points) : 0
        }

        // Every candidate is a step from `period`; the best wins, `period`
        // itself on a tie, then the one nearest the low end. Rather than
        // score each one, the steps are taken in blocks: a block's bound,
        // the onsets in a window wide enough for every grid in it over the
        // fewest beats any of them has, is at least what any of its grids
        // scores. Blocks are scored in the order of their bounds, until the
        // bound falls below the best found.
        let blockRadius = 8
        let blockSpan = reach * Double(2 * blockRadius) / Double(steps)
        let most = beats(candidate(-steps))
        let wander = Double(max(most.before, most.after) + 1) * blockSpan * curve.framesPerSecond
        // Each grid point also rounds to a frame, and the strength reads
        // a frame past its reach either way.
        let window = Int((wander / 2 + strengthReach).rounded(.up)) + 2
        let widened = curve.localMax(window: window)
        func bound(_ low: Int, _ high: Int) -> Double {
            let fewest = beats(candidate(high))
            let grid = (candidate(low) + candidate(high)) / 2
            let reaching = beats(candidate(low))
            var total = 0.0
            for k in stride(from: 1.0, through: Double(reaching.before), by: 1) {
                total += Double(widened.value(at: OnsetCurve.index(curve.frame(atSeconds: first - k * grid).rounded())))
            }
            for k in stride(from: 1.0, through: Double(reaching.after), by: 1) {
                total += Double(widened.value(at: OnsetCurve.index(curve.frame(atSeconds: last + k * grid).rounded())))
            }
            let points = fewest.before + fewest.after
            return points > 0 ? total / Double(points) : .infinity
        }
        var blocks: [(low: Int, high: Int, bound: Double)] = []
        for low in stride(from: -steps, through: steps, by: 2 * blockRadius + 1) {
            if Task.isCancelled { throw CancellationError() }
            let high = min(steps, low + 2 * blockRadius)
            blocks.append((low, high, bound(low, high)))
        }
        blocks.sort { $0.bound > $1.bound || ($0.bound == $1.bound && $0.low < $1.low) }
        var rough = period, roughIndex = 0, roughScore = score(period)
        for block in blocks {
            // A bound only just below the best may differ by rounding alone.
            guard block.bound * (1 + 1e-9) >= roughScore else { break }
            if Task.isCancelled { throw CancellationError() }
            for index in block.low...block.high where index != 0 {
                let value = score(candidate(index))
                if value > roughScore || (value == roughScore && roughIndex != 0 && index < roughIndex) {
                    rough = candidate(index)
                    roughIndex = index
                    roughScore = value
                }
            }
        }
        // That finds the neighbourhood; within it every period whose far
        // beats stay near their onsets scores alike. The onset peaks near
        // the grid, placed between frames, settle it by least squares: each
        // side steps from its own outer anchor, k beats out.
        var numerator = 0.0, denominator = 0.0
        func fit(from anchor: Double, direction: Double, count: Int) {
            for k in stride(from: 1.0, through: Double(count), by: 1) {
                let found = curve.peak(near: curve.frame(atSeconds: anchor + direction * k * rough), reach: strengthReach)
                if found.strength >= weakOnset {
                    let signed = direction * k
                    numerator += signed * (curve.seconds(atFrame: found.frame) - anchor)
                    denominator += signed * signed
                }
            }
        }
        let fitted = beats(rough)
        fit(from: first, direction: -1, count: fitted.before)
        fit(from: last, direction: 1, count: fitted.after)
        guard denominator > 0 else { return rough }
        return (numerator / denominator).clamped(between: period - reach, and: period + reach)
    }

    // MARK: Doubling and halving

    /// The slowest tempo halving may give, in beats per minute.
    static let slowestHalved = BeatTracker.minimumBPM / 2
    /// The fastest tempo doubling may give.
    static let fastestDoubled = BeatTracker.maximumBPM * 2

    /// Twice the tempo, done on the beats themselves rather than by fitting
    /// again, so nothing else moves: a beat half way between each two, and
    /// half a beat past each end where the section reaches. The new beats
    /// snap onto onsets like any other.
    static func doubled(_ section: BeatSection, curve: OnsetCurve, sampleRate: Double) -> BeatSection {
        let times = section.beats.map(\.time.seconds)
        guard times.count >= 2, let period = medianGap(of: times), 60 / period * 2 <= fastestDoubled else { return section }
        var added = zip(times, times.dropFirst()).map { ($0 + $1) / 2 }
        if times[0] - period / 2 >= section.start.seconds { added.append(times[0] - period / 2) }
        if times[times.count - 1] + period / 2 < section.end.seconds { added.append(times[times.count - 1] + period / 2) }
        let aligned = aligned(curve, to: section.pinnedBeats.map(\.time.seconds))
        var result = section
        result.beats += snapped(added.map { MappedBeat(time: time($0, sampleRate: sampleRate)) }, curve: aligned, sampleRate: sampleRate)
        result.normalize()
        return result
    }

    /// Which beats halving keeps, every other one: those level with the
    /// pinned beats, or with the downbeats when nothing is pinned. Nil when
    /// halving can't keep them all (pinned beats on both sides of the
    /// split), when too few beats are left, or when the tempo would fall
    /// below `slowestHalved`.
    static func halvingParity(of section: BeatSection) -> Int? {
        let beats = section.beats
        guard beats.count >= 3, let period = medianGap(of: beats.map(\.time.seconds)), 60 / period / 2 >= slowestHalved else { return nil }
        let pinned = Set(beats.indices.filter { beats[$0].isPinned }.map { $0 % 2 })
        if pinned.count > 1 { return nil }
        if let parity = pinned.first { return parity }
        let downbeats = beats.indices.filter { beats[$0].isDownbeat }
        return downbeats.filter { $0 % 2 == 1 }.count > downbeats.count / 2 ? 1 : 0
    }

    /// Half the tempo: every other beat, as `halvingParity` picks.
    static func halved(_ section: BeatSection) -> BeatSection {
        guard let parity = halvingParity(of: section) else { return section }
        var result = section
        result.beats = section.beats.indices.filter { $0 % 2 == parity }.map { section.beats[$0] }
        return result
    }

    // MARK: Ramps

    /// Fills a ramp between the filled sections either side of it. Its
    /// pinned beats are kept, and an end without a neighbour needs a
    /// measure's beats pinned there instead.
    ///
    /// Between each two fixed beats the chain is run for each count near
    /// what an even change of tempo would hold, expecting the period to
    /// move from one end's to the other's; the count whose chain lands on
    /// the strongest onsets wins.
    static func fillRamp(
        _ section: BeatSection, before: BeatSection?, after: BeatSection?, curve: OnsetCurve, sampleRate: Double
    ) throws -> BeatSection {
        try rampFill(section, before: before, after: after, curve: curve, sampleRate: sampleRate).section
    }

    private static func rampFill(
        _ section: BeatSection, before: BeatSection?, after: BeatSection?, curve: OnsetCurve, sampleRate: Double
    ) throws -> (section: BeatSection, report: FillReport) {
        let pinned = distinctPins(of: section, sampleRate: sampleRate)
        let pins = pinned.map(\.time.seconds)
        let start = section.start.seconds, end = section.end.seconds
        // Fixed beats, each with the period around it.
        var fixed: [(time: Double, period: Double?)] = []
        if let before, let last = before.beats.last {
            fixed.append((last.time.seconds, medianGap(of: before.beats.suffix(5).map(\.time.seconds))))
        }
        fixed += pins.map { ($0, nil) }
        if let after, let first = after.beats.first {
            fixed.append((first.time.seconds, medianGap(of: after.beats.prefix(5).map(\.time.seconds))))
        }
        // An end without a neighbour takes its period from the measure
        // marked there; with neither, each end needs its own.
        let runs = measureRuns(pins, sampleRate: sampleRate)
        if before == nil {
            guard let run = runs.first, run.count >= 2, !fixed.isEmpty else { throw Failure.needsBothEnds }
            fixed[0].period = medianGap(of: run)
        }
        if after == nil {
            guard let run = runs.last, run.count >= 2, before != nil || runs.count >= 2, !fixed.isEmpty else { throw Failure.needsBothEnds }
            fixed[fixed.count - 1].period = medianGap(of: run)
        }
        guard fixed.count >= 2, let startPeriod = fixed.first?.period, let endPeriod = fixed.last?.period else {
            throw Failure.needsBothEnds
        }
        guard usable(startPeriod), usable(endPeriod) else { throw Failure.unusableTempo }
        let curve = aligned(curve, to: fixed.map(\.time))
        // Inner pinned beats: the period where they are on an even ramp.
        let span = fixed[fixed.count - 1].time - fixed[0].time
        let periods = fixed.map { point in
            point.period ?? startPeriod + (endPeriod - startPeriod) * (point.time - fixed[0].time) / max(span, 1e-9)
        }

        var report = FillReport()
        var times: [Double] = []
        if before == nil {
            let stepped = steps(from: fixed[0].time, period: startPeriod, direction: -1, limit: start, curve: curve, refine: true)
            times += stepped.times.reversed()
            report.droppedSilentBeats += stepped.dropped
        }
        var scratch = ChainScratch()
        for index in 0..<(fixed.count - 1) where fixed[index + 1].time > fixed[index].time {
            times += try rampChain(
                from: fixed[index].time, to: fixed[index + 1].time,
                periods: (periods[index], periods[index + 1]), curve: curve, scratch: &scratch
            )
        }
        if after == nil {
            let stepped = steps(from: fixed[fixed.count - 1].time, period: endPeriod, direction: 1, limit: end, curve: curve, refine: true)
            times += stepped.times
            report.droppedSilentBeats += stepped.dropped
        }

        // The chains run between fixed beats, so only the steps past an open
        // end needed limiting to the section.
        var quiet = 0
        var filled = section
        filled.beats = snapped(
            pinned + times.filter(\.isFinite).map { MappedBeat(time: time($0, sampleRate: sampleRate)) },
            curve: curve, sampleRate: sampleRate, quiet: &quiet
        )
        filled.isConfirmed = true
        filled.normalize()
        report.beatCount = filled.beats.count
        report.quietBeats = quiet
        return (filled, report)
    }

    /// The beats strictly between two fixed beats of a ramp whose period
    /// goes from `periods.0` to `periods.1`.
    private static func rampChain(
        from a: Double, to b: Double, periods: (Double, Double), curve: OnsetCurve, scratch: inout ChainScratch
    ) throws -> [Double] {
        let expected = (b - a) / ((periods.0 + periods.1) / 2)
        guard expected.isFinite, expected > 0 else { throw Failure.unusableTempo }
        let low = max(1, Int((expected * 0.85).rounded(.down))), high = max(low, Int((expected * 1.15).rounded(.up)))
        var best: (times: [Double], score: Double)?
        for count in low...high {
            if Task.isCancelled { throw CancellationError() }
            // The gaps grow or shrink evenly from one end's period to the
            // other's, scaled to fit between the two beats exactly.
            let gaps = (0..<count).map { periods.0 + (periods.1 - periods.0) * (Double($0) + 0.5) / Double(count) }
            let total = gaps.reduce(0, +)
            var ideal: [Double] = [], position = a
            ideal.reserveCapacity(count - 1)
            for gap in gaps.dropLast() {
                position += gap * (b - a) / total
                ideal.append(position)
            }
            var result = try chain(from: a, to: b, ideal: ideal, curve: curve, reach: rampReach, scratch: &scratch)
            // The chain fits any count between the two beats, so a count far
            // from what the two periods suggest costs a little, softly:
            // ramps are seldom even.
            let stray = log(expected / Double(count))
            result.score -= rampCountWeight * stray * stray
            if best == nil || result.score > best!.score { best = result }
        }
        return best?.times ?? []
    }

    // MARK: Chains

    /// The buffers a chain works in, kept from one chain to the next when
    /// several are run for one fill.
    struct ChainScratch {
        var previous: [Double] = []
        var row: [Double] = []
        var links: [Int32] = []
        var penalties: [Double] = []
    }

    /// Beats near each of the `ideal` times, in order, between two fixed
    /// beats at `a` and `b`: the string that lands on the strongest onsets
    /// while keeping each gap close to the ideal one (Ellis's dynamic
    /// programming, held at both ends). The score is per gap, so chains of
    /// different counts compare.
    static func chain(from a: Double, to b: Double, ideal: [Double], curve: OnsetCurve, reach share: Double) throws -> (times: [Double], score: Double) {
        var scratch = ChainScratch()
        return try chain(from: a, to: b, ideal: ideal, curve: curve, reach: share, scratch: &scratch)
    }

    static func chain(
        from a: Double, to b: Double, ideal: [Double], curve: OnsetCurve, reach share: Double, scratch: inout ChainScratch
    ) throws -> (times: [Double], score: Double) {
        guard !ideal.isEmpty else { return ([], 0) }
        let frames = ([a] + ideal + [b]).map(curve.frame(atSeconds:))
        guard frames.allSatisfy(\.isFinite) else { return (ideal, -.infinity) }
        // Candidate frames for each inner beat: `lows[i]` and on, `widths[i]` of them.
        let inner = ideal.count
        var lows = [Int](repeating: 0, count: inner), widths = [Int](repeating: 0, count: inner), offsets = [Int](repeating: 0, count: inner)
        var totalCandidates = 0
        for index in 0..<inner {
            let frame = frames[index + 1]
            let gap = min(frame - frames[index], frames[index + 2] - frame)
            let reach = min(max(1, gap * share), Double(chainReachFrames))
            let low = OnsetCurve.index((frame - reach).rounded(.down)), high = OnsetCurve.index((frame + reach).rounded(.up))
            lows[index] = low
            widths[index] = max(low, high) - low + 1
            offsets[index] = totalCandidates
            totalCandidates += widths[index]
        }
        func penalty(_ gap: Double, expected: Double) -> Double {
            guard gap > 0, expected > 0 else { return .infinity }
            let stray = log(gap / expected)
            return tightness * stray * stray
        }
        // previous[j]: the best total ending with the last inner beat at
        // candidate j; links: which candidate of the beat before each came from.
        scratch.links.removeAll(keepingCapacity: true)
        scratch.links.append(contentsOf: repeatElement(-1, count: totalCandidates))
        try curve.values.withUnsafeBufferPointer { values in
            func onset(_ frame: Int) -> Double { frame >= 0 && frame < values.count ? Double(values[frame]) : 0 }
            for index in 0..<inner {
                if Task.isCancelled { throw CancellationError() }
                let expected = frames[index + 1] - frames[index]
                let low = lows[index], width = widths[index]
                scratch.row.removeAll(keepingCapacity: true)
                scratch.row.append(contentsOf: repeatElement(-.infinity, count: width))
                if index == 0 {
                    for k in 0..<width {
                        scratch.row[k] = onset(low + k) - penalty(Double(low + k) - frames[0], expected: expected)
                    }
                } else {
                    // Every gap between a candidate here and one before is a
                    // whole number of frames in a short range: its penalty is
                    // worked out once.
                    let previousLow = lows[index - 1], previousWidth = widths[index - 1]
                    let shortest = low - (previousLow + previousWidth - 1)
                    let longest = low + width - 1 - previousLow
                    scratch.penalties.removeAll(keepingCapacity: true)
                    for gap in shortest...longest { scratch.penalties.append(penalty(Double(gap), expected: expected)) }
                    let offset = offsets[index]
                    for k in 0..<width {
                        var best = -Double.infinity, link: Int32 = -1
                        let frame = low + k
                        for j in 0..<previousWidth {
                            let total = scratch.previous[j] - scratch.penalties[frame - (previousLow + j) - shortest]
                            if total > best {
                                best = total
                                link = Int32(j)
                            }
                        }
                        scratch.row[k] = best + onset(frame)
                        scratch.links[offset + k] = link
                    }
                }
                swap(&scratch.previous, &scratch.row)
            }
        }
        let lastExpected = frames[frames.count - 1] - frames[frames.count - 2]
        let lastLow = lows[inner - 1]
        var bestK = 0, bestTotal = -Double.infinity
        for k in 0..<widths[inner - 1] {
            let total = scratch.previous[k] - penalty(frames[frames.count - 1] - Double(lastLow + k), expected: lastExpected)
            if total > bestTotal {
                bestTotal = total
                bestK = k
            }
        }
        // No string of candidates keeps every gap open (anchors a frame or
        // two apart): the even places, as poor as can be.
        guard bestTotal > -.infinity else { return (ideal, -.infinity) }
        var picked = [Int](repeating: 0, count: inner)
        var k = bestK
        for index in stride(from: inner - 1, through: 0, by: -1) {
            picked[index] = lows[index] + k
            if index > 0 { k = Int(scratch.links[offsets[index] + k]) }
        }
        let times = picked.map { curve.seconds(atFrame: Double($0) + curve.subframeOffset(at: $0)) }
        return (times, bestTotal / Double(ideal.count + 1))
    }

    /// Beats stepping on from a fixed beat, one period at a time, up to
    /// (and not including) `limit`. Refined steps move to the strongest
    /// onset near where the next beat should be, so they follow drift;
    /// through a short quiet stretch they keep the period. Stepping stops
    /// where the music does: after `silentBeats` steps in a row with no
    /// onset anywhere in the step, which are dropped, so a drawn edge past
    /// the end of the song doesn't fill silence with beats. A beat with no
    /// hit on it but something between it and the last (a held chord, a
    /// vocal) is music, not silence.
    static func stepping(from time: Double, period: Double, direction: Double, limit: Double, curve: OnsetCurve, refine: Bool) -> [Double] {
        steps(from: time, period: period, direction: direction, limit: limit, curve: curve, refine: refine).times
    }

    /// `stepping`, and how many steps it dropped as silence.
    private static func steps(
        from time: Double, period: Double, direction: Double, limit: Double, curve: OnsetCurve, refine: Bool
    ) -> (times: [Double], dropped: Int) {
        let distance = (limit - time) * direction
        guard usable(period), time.isFinite, distance.isFinite, distance > 0 else { return ([], 0) }
        // A refined step moves at least half a period, so this many always
        // reach the limit or the silence.
        let most = Int(min(distance / (0.5 * period), 1e7).rounded(.up)) + silentBeats + 1
        var times: [Double] = []
        times.reserveCapacity(min(most, Int((distance / period).rounded(.up)) + 1))
        var previous = time
        var silent = 0
        // Exact steps are counted from the anchor, so they don't add up rounding.
        var step = 1.0
        let reach = period * steadyReach * curve.framesPerSecond
        while times.count < most {
            var next = refine ? previous + direction * period : time + direction * period * step
            if refine {
                let found = curve.peak(near: curve.frame(atSeconds: next), reach: reach)
                if found.strength >= weakOnset {
                    let moved = curve.seconds(atFrame: found.frame)
                    if abs(moved - previous) > period * 0.5 { next = moved }
                }
            }
            if direction > 0 ? next >= limit : next < limit {
                // Up to the edge, but not into silence.
                times.removeLast(silent)
                return (times, silent)
            }
            // From clear of the last beat's own hit to just past this one's.
            let stepStart = previous + direction * period * 0.15, stepEnd = next + direction * period * steadyReach
            silent = hasOnset(curve, between: stepStart, and: stepEnd) ? 0 : silent + 1
            if silent >= silentBeats {
                times.removeLast(silent - 1)
                return (times, silent)
            }
            times.append(next)
            previous = next
            step += 1
        }
        return (times, 0)
    }

    /// See `stepping`: two measures of four.
    static let silentBeats = 8

    /// Whether anything starts in the curve between two times.
    private static func hasOnset(_ curve: OnsetCurve, between a: Double, and b: Double) -> Bool {
        let low = OnsetCurve.index(curve.frame(atSeconds: min(a, b)).rounded(.up)), high = OnsetCurve.index(curve.frame(atSeconds: max(a, b)))
        return hasOnset(curve, from: low, through: high)
    }

    /// Whether anything starts in the curve from frame `low` through `high`.
    private static func hasOnset(_ curve: OnsetCurve, from low: Int, through high: Int) -> Bool {
        // Frames past the ends are 0, never an onset.
        let first = max(low, 0), last = min(high, curve.values.count - 1)
        guard first <= last else { return false }
        return curve.values.withUnsafeBufferPointer { values in
            (first...last).contains { values[$0] >= weakOnset }
        }
    }

    // MARK: Onset timing

    /// How far, in seconds, any beat, pinned or not, may be moved onto a
    /// clear onset: closer than anyone can place a beat by ear, and far
    /// short of the next beat at any tempo.
    static let snapReach = 0.015

    /// The beats moved onto the strongest clear onset within `snapReach`
    /// of each, on a curve already aligned to how the beats are heard. A
    /// beat with no clear onset near stays where it is: in a section
    /// produced to a click, that keeps the grid through quiet beats. A
    /// pinned beat that moves keeps where it was put as its `heardTime`,
    /// and one whose snap was undone (`snapsToOnset` off) stays put.
    static func snapped(_ beats: [MappedBeat], curve: OnsetCurve, sampleRate: Double) -> [MappedBeat] {
        var quiet = 0
        return snapped(beats, curve: curve, sampleRate: sampleRate, quiet: &quiet)
    }

    /// `snapped`, counting in `quiet` the beats with no clear onset near.
    static func snapped(_ beats: [MappedBeat], curve: OnsetCurve, sampleRate: Double, quiet: inout Int) -> [MappedBeat] {
        let reach = snapReach * curve.framesPerSecond
        var stayed = 0
        let result = beats.map { beat in
            guard beat.snapsToOnset, beat.time.isNumeric else { return beat }
            let peak = curve.peak(near: curve.frame(atSeconds: beat.time.seconds), reach: reach)
            guard peak.strength >= weakOnset else {
                stayed += 1
                return beat
            }
            let target = time(curve.seconds(atFrame: peak.frame), sampleRate: sampleRate)
            guard target.isNumeric, CMTimeCompare(target, beat.time) != 0 else { return beat }
            var moved = beat
            moved.time = target
            if beat.isPinned { moved.heardTime = beat.heardTime ?? beat.time }
            return moved
        }
        quiet += stayed
        return result
    }

    /// How much earlier than the hit itself the onset curve peaks, in
    /// seconds: spectral flux rises as soon as the hit enters the analysis
    /// window, which is centered after it. Measured on sharp clicks; used
    /// when no anchor sits on a clear onset.
    static let onsetLead = 0.0143

    /// The curve moved so its peaks line up with the beats as the person
    /// hears them: by the median distance from each fixed beat (lined up by
    /// ear) to the onset peak nearest it, which takes in how soft the
    /// song's attacks are, or by `onsetLead` when no fixed beat is on one.
    static func aligned(_ curve: OnsetCurve, to fixed: [Double]) -> OnsetCurve {
        let reach = 0.03 * curve.framesPerSecond
        let leads = fixed.compactMap { time -> Double? in
            guard time.isFinite else { return nil }
            let peak = curve.peak(near: curve.frame(atSeconds: time), reach: reach)
            guard peak.strength >= weakOnset else { return nil }
            return time - curve.seconds(atFrame: peak.frame)
        }.sorted()
        var moved = curve
        // The median; for an even count, the mean of the middle two, so two
        // anchors off in opposite directions each end up half way.
        let middle = leads.count / 2
        let lead = leads.isEmpty ? onsetLead
            : leads.count.isMultiple(of: 2) ? (leads[middle - 1] + leads[middle]) / 2 : leads[middle]
        moved.start += lead.clamped(between: -0.05, and: 0.05)
        return moved
    }

    // MARK: Helpers

    /// Pinned beats in runs of consecutive beats, such as a marked measure:
    /// split wherever a gap is over twice the typical one. That is the
    /// shortest gap, unless two beats sit within a sample at `sampleRate`
    /// of each other, when it is the median.
    static func measureRuns(_ times: [Double], sampleRate: Double = 48_000) -> [[Double]] {
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        guard var typical = gaps.min() else { return times.isEmpty ? [] : [times] }
        if typical <= 1 / max(1, sampleRate) { typical = medianGap(of: times) ?? 0 }
        guard typical > 0 else { return [times] }
        var runs: [[Double]] = [[times[0]]]
        for (previous, time) in zip(times, times.dropFirst()) {
            if time - previous > 2 * typical { runs.append([time]) } else { runs[runs.count - 1].append(time) }
        }
        return runs
    }

    /// The median gap between consecutive times, nil with fewer than two.
    static func medianGap(of times: [Double]) -> Double? {
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return nil }
        let middle = gaps.count / 2
        return gaps.count.isMultiple(of: 2) ? (gaps[middle - 1] + gaps[middle]) / 2 : gaps[middle]
    }

    /// `seconds` on the nearest sample at `sampleRate`; invalid for a time
    /// that isn't a number or is past what a time can hold.
    static func time(_ seconds: Double, sampleRate: Double) -> CMTime {
        let rate = Int32(max(1, min(sampleRate.isFinite ? sampleRate.rounded() : 48_000, Double(Int32.max))))
        let samples = (seconds * Double(rate)).rounded()
        guard samples.isFinite, abs(samples) < 9e18 else { return .invalid }
        return CMTime(value: Int64(samples), timescale: rate)
    }
}
