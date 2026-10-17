import CoreMedia
import Foundation

/// An onset curve (see `OnsetAnalyzer`) prepared for fitting beats to: what
/// stands out from the surrounding second, scaled to unit spread. Frame
/// positions are in the asset's original time, the time of a beat map.
struct OnsetCurve: Sendable, Equatable {
    var values: [Float]
    var framesPerSecond: Double
    /// The original time, in seconds, of frame 0's center.
    var start: Double

    func frame(atSeconds seconds: Double) -> Double { (seconds - start) * framesPerSecond }
    func seconds(atFrame frame: Double) -> Double { start + frame / framesPerSecond }

    func value(at frame: Int) -> Float {
        values.indices.contains(frame) ? values[frame] : 0
    }

    /// The strongest onset within `reach` frames of `frame`, and where it
    /// is, refined between frames by fitting a parabola through the peak.
    func peak(near frame: Double, reach: Double) -> (frame: Double, strength: Float) {
        let low = Int((frame - reach).rounded(.down)), high = Int((frame + reach).rounded(.up))
        var best = Int(frame.rounded()), strength = value(at: best)
        if low <= high {
            for candidate in low...high where value(at: candidate) > strength {
                best = candidate
                strength = value(at: candidate)
            }
        }
        return (Double(best) + subframeOffset(at: best), strength)
    }

    /// Where between frames the peak at `frame` really is, from the
    /// parabola through it and its neighbours; 0 unless it is a peak.
    func subframeOffset(at frame: Int) -> Double {
        let left = Double(value(at: frame - 1)), middle = Double(value(at: frame)), right = Double(value(at: frame + 1))
        let curve = left - 2 * middle + right
        guard middle >= left, middle >= right, curve < 0 else { return 0 }
        return min(max(0.5 * (left - right) / curve, -0.5), 0.5)
    }
}

/// Fills the sections of a beat map from the beats the person pinned: see
/// docs/beat-matching.md. Everything works in seconds of original time on
/// an `OnsetCurve`, and is a pure function of its inputs.
enum BeatFitting {
    enum Failure: LocalizedError, Equatable {
        /// A consistent section is filled from two anchors.
        case needsTwoAnchors
        /// A ramp needs a filled section, or a marked measure, at each end.
        case needsBothEnds
        /// Only consistent sections and ramps have beats.
        case notAnalyzed

        var errorDescription: String? {
            switch self {
            case .needsTwoAnchors: "Place two anchor beats first."
            case .needsBothEnds: "A ramp needs a filled section on each side, or every beat of one measure marked at an end without one."
            case .notAnalyzed: "This section isn't analyzed."
            }
        }
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
        guard let index = map.sections.firstIndex(where: { $0.id == id }) else { return map }
        var map = map
        let section = map.sections[index]
        switch section.kind {
        case .consistent:
            let filled = try fillConsistent(section, curve: curve, sampleRate: sampleRate, tempo: tempo)
            map.sections[index] = filled.section
            snapEdges(of: index, in: &map, period: filled.period, sampleRate: sampleRate, duration: duration)
        case .ramp:
            map.sections[index] = try fillRamp(
                section, before: neighbour(of: index, in: map, step: -1), after: neighbour(of: index, in: map, step: 1),
                curve: curve, sampleRate: sampleRate
            )
        case .none:
            throw Failure.notAnalyzed
        }
        map.recountPositions()
        return map
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

    private static func snapEdges(of index: Int, in map: inout BeatMap, period: Double, sampleRate: Double, duration: CMTime) {
        let section = map.sections[index]
        guard let first = section.beats.first, let last = section.beats.last else { return }
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
        let start = CMTimeMaximum(first.time, lowest)
        let end = CMTimeMinimum(time(last.time.seconds + period, sampleRate: sampleRate), highest)
        guard CMTimeCompare(start, end) < 0 else { return }
        if index > 0, touches(map.sections[index - 1].end, section.start), CMTimeCompare(map.sections[index - 1].start, start) < 0 {
            map.sections[index - 1].end = start
        }
        if index + 1 < map.sections.count, touches(map.sections[index + 1].start, section.end),
           CMTimeCompare(end, map.sections[index + 1].end) < 0 {
            map.sections[index + 1].start = end
        }
        map.sections[index].start = start
        map.sections[index].end = end
    }


    // MARK: Consistent sections

    /// Fills a consistent section from its pinned beats (at least two),
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
        let pins = section.pinnedBeats
        guard pins.count >= 2 else { throw Failure.needsTwoAnchors }
        let pinTimes = pins.map(\.time.seconds)
        let curve = aligned(curve, to: pinTimes)
        let start = section.start.seconds, end = section.end.seconds
        let reanalyzing = section.isConfirmed && section.beats.count > pins.count

        var period: Double
        var counts: [Int]
        let gaps = zip(pinTimes, pinTimes.dropFirst()).map { $1 - $0 }
        if let tempo, tempo > 0 {
            period = 60 / tempo
            counts = gaps.map { max(1, Int(($0 / period).rounded())) }
        } else if reanalyzing, let typical = medianGap(of: section.beats.map(\.time.seconds)) {
            period = typical
            counts = gaps.map { max(1, Int(($0 / period).rounded())) }
        } else {
            let estimate = estimatedPeriod(curve: curve, from: max(start, pinTimes.first! - 4), to: min(end, pinTimes.last! + 4))
                ?? gaps.max()! / max(1, (gaps.max()! / 0.5).rounded())
            // The widest pair decides the tempo; the rest round to it.
            let widest = gaps.indices.max { gaps[$0] < gaps[$1] }!
            let count = beatCount(
                from: pinTimes[widest], to: pinTimes[widest + 1], period: estimate, curve: curve,
                positions: (pins[widest].position, pins[widest + 1].position), beatsPerMeasure: section.beatsPerMeasure,
                refined: section.steadiness == .intent
            )
            period = gaps[widest] / Double(count)
            counts = gaps.map { max(1, Int(($0 / period).rounded())) }
            counts[widest] = count
        }
        // What the pinned beats say the tempo is, all of them counted.
        period = zip(gaps, counts).map { $0 / Double($1) }.sorted()[gaps.count / 2]

        let refine = section.steadiness == .intent
        var times: [Double] = []
        times += stepping(from: pinTimes.first!, period: gaps.isEmpty ? period : gaps[0] / Double(counts[0]),
                          direction: -1, limit: start, curve: curve, refine: refine).reversed()
        for (index, gap) in gaps.enumerated() {
            let a = pinTimes[index], b = pinTimes[index + 1], count = counts[index]
            let ideal = (1..<count).map { a + gap * Double($0) / Double(count) }
            times += refine ? chain(from: a, to: b, ideal: ideal, curve: curve, reach: chainReach).times : ideal
        }
        times += stepping(from: pinTimes.last!, period: gaps[gaps.count - 1] / Double(counts[counts.count - 1]),
                          direction: 1, limit: end, curve: curve, refine: refine)

        var filled = section
        filled.beats = pins + times.filter { $0 >= start && $0 < end }.map { MappedBeat(time: time($0, sampleRate: sampleRate)) }
        filled.isConfirmed = true
        filled.normalize()
        return (filled, period)
    }

    /// The beat period, in seconds, that the onsets between two times
    /// repeat at most, weighted toward everyday tempos the way detection
    /// is; nil with too little to tell.
    static func estimatedPeriod(curve: OnsetCurve, from: Double, to: Double) -> Double? {
        let first = max(0, Int(curve.frame(atSeconds: from))), last = min(curve.values.count, Int(curve.frame(atSeconds: to)))
        let rate = curve.framesPerSecond
        let shortest = max(2, Int((rate * 60 / BeatTracker.maximumBPM).rounded(.down)))
        let longest = Int((rate * 60 / BeatTracker.minimumBPM).rounded(.up))
        guard last - first > 2 * longest else { return nil }
        let preferred = rate * 60 / BeatTracker.preferredBPM
        var scores: [Double] = []
        curve.values.withUnsafeBufferPointer { values in
            for lag in shortest...longest {
                var sum = 0.0
                for frame in first..<(last - lag) {
                    sum += Double(values[frame]) * Double(values[frame + lag])
                }
                let octaves = log2(Double(lag) / preferred) / 1.4
                scores.append(sum / Double(last - lag - first) * exp(-0.5 * octaves * octaves))
            }
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { return nil }
        var lag = Double(shortest + best)
        if best > 0, best + 1 < scores.count {
            let left = scores[best - 1], middle = scores[best], right = scores[best + 1]
            let bend = left - 2 * middle + right
            if bend < 0 { lag += min(max(0.5 * (left - right) / bend, -0.5), 0.5) }
        }
        return lag / rate
    }

    /// How many beat periods lie between two anchors: near the gap over
    /// `period`, a count that keeps the anchors' places in the measure if
    /// one is close enough, and among those the one that lands on the
    /// strongest onsets. That is an even grid for a section produced to a
    /// click, and the refined chain for one steady by intent, whose drift
    /// takes an even grid off the beats.
    static func beatCount(
        from a: Double, to b: Double, period: Double, curve: OnsetCurve,
        positions: (Int, Int), beatsPerMeasure: Int, refined: Bool = false
    ) -> Int {
        let expected = (b - a) / period
        let low = max(1, Int((expected * (1 - countSearch)).rounded(.down)))
        let high = max(low, Int((expected * (1 + countSearch)).rounded(.up)))
        let scored = (low...high).map { count -> (count: Int, score: Double) in
            guard refined else { return (count, gridScore(from: a, to: b, count: count, curve: curve)) }
            let ideal = (1..<count).map { a + (b - a) * Double($0) / Double(count) }
            return (count, chain(from: a, to: b, ideal: ideal, curve: curve, reach: chainReach).score)
        }
        let best = scored.max { $0.score < $1.score }!
        // The measure is a strong hint, not a rule: anchors given the wrong
        // places shouldn't force a count the onsets plainly disagree with.
        let measured = scored.filter { ($0.count - (positions.1 - positions.0)).modulo(beatsPerMeasure) == 0 }
        guard let fitting = measured.max(by: { $0.score < $1.score }),
              fitting.score >= best.score - (1 - measureHint) * abs(best.score)
        else {
            return best.count
        }
        return fitting.count
    }

    /// The mean onset under an even grid of `count` steps from `a` to `b`,
    /// each taken within a few milliseconds of its place.
    static func gridScore(from a: Double, to b: Double, count: Int, curve: OnsetCurve) -> Double {
        let reach = max(1, 0.006 * curve.framesPerSecond)
        var total = 0.0
        for step in 0...count {
            let seconds = a + (b - a) * Double(step) / Double(count)
            total += Double(curve.peak(near: curve.frame(atSeconds: seconds), reach: reach).strength)
        }
        return total / Double(count + 1)
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
        let pins = section.pinnedBeats.map(\.time.seconds)
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
        let runs = measureRuns(pins)
        if before == nil {
            guard let run = runs.first, run.count >= 2 else { throw Failure.needsBothEnds }
            fixed[0].period = medianGap(of: run)
        }
        if after == nil {
            guard let run = runs.last, run.count >= 2, before != nil || runs.count >= 2 else { throw Failure.needsBothEnds }
            fixed[fixed.count - 1].period = medianGap(of: run)
        }
        guard fixed.count >= 2, let startPeriod = fixed.first?.period, let endPeriod = fixed.last?.period else {
            throw Failure.needsBothEnds
        }
        let curve = aligned(curve, to: fixed.map(\.time))
        // Inner pinned beats: the period where they are on an even ramp.
        let span = fixed[fixed.count - 1].time - fixed[0].time
        let periods = fixed.map { point in
            point.period ?? startPeriod + (endPeriod - startPeriod) * (point.time - fixed[0].time) / max(span, 1e-9)
        }

        var times: [Double] = []
        if before == nil {
            times += stepping(from: fixed[0].time, period: startPeriod, direction: -1, limit: start, curve: curve, refine: true).reversed()
        }
        for index in 0..<(fixed.count - 1) {
            times += rampChain(
                from: fixed[index].time, to: fixed[index + 1].time,
                periods: (periods[index], periods[index + 1]), curve: curve
            )
        }
        if after == nil {
            times += stepping(from: fixed[fixed.count - 1].time, period: endPeriod, direction: 1, limit: end, curve: curve, refine: true)
        }

        // The chains run between fixed beats, so only the steps past an open
        // end needed limiting to the section.
        var filled = section
        filled.beats = section.pinnedBeats + times.map { MappedBeat(time: time($0, sampleRate: sampleRate)) }
        filled.isConfirmed = true
        filled.normalize()
        return filled
    }

    /// The beats strictly between two fixed beats of a ramp whose period
    /// goes from `periods.0` to `periods.1`.
    private static func rampChain(from a: Double, to b: Double, periods: (Double, Double), curve: OnsetCurve) -> [Double] {
        let expected = (b - a) / ((periods.0 + periods.1) / 2)
        let low = max(1, Int((expected * 0.85).rounded(.down))), high = max(low, Int((expected * 1.15).rounded(.up)))
        var best: (times: [Double], score: Double)?
        for count in low...high {
            // The gaps grow or shrink evenly from one end's period to the
            // other's, scaled to fit between the two beats exactly.
            let gaps = (0..<count).map { periods.0 + (periods.1 - periods.0) * (Double($0) + 0.5) / Double(count) }
            let total = gaps.reduce(0, +)
            var ideal: [Double] = [], position = a
            for gap in gaps.dropLast() {
                position += gap * (b - a) / total
                ideal.append(position)
            }
            var result = chain(from: a, to: b, ideal: ideal, curve: curve, reach: rampReach)
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

    /// Beats near each of the `ideal` times, in order, between two fixed
    /// beats at `a` and `b`: the string that lands on the strongest onsets
    /// while keeping each gap close to the ideal one (Ellis's dynamic
    /// programming, held at both ends). The score is per gap, so chains of
    /// different counts compare.
    static func chain(from a: Double, to b: Double, ideal: [Double], curve: OnsetCurve, reach share: Double) -> (times: [Double], score: Double) {
        let anchors = [a] + ideal + [b]
        let frames = anchors.map(curve.frame(atSeconds:))
        guard !ideal.isEmpty else { return ([], 0) }
        // Candidate frames for each inner beat.
        var candidates: [[Int]] = []
        for index in 1..<(frames.count - 1) {
            let gap = min(frames[index] - frames[index - 1], frames[index + 1] - frames[index])
            let reach = max(1, gap * share)
            let low = Int((frames[index] - reach).rounded(.down)), high = Int((frames[index] + reach).rounded(.up))
            candidates.append(Array(low...max(low, high)))
        }
        func penalty(_ gap: Double, expected: Double) -> Double {
            guard gap > 0, expected > 0 else { return .infinity }
            let stray = log(gap / expected)
            return tightness * stray * stray
        }
        // scores[i][k]: best total ending with inner beat i at candidate k.
        var scores: [[Double]] = []
        var links: [[Int]] = []
        for (index, options) in candidates.enumerated() {
            let expected = frames[index + 1] - frames[index]
            var row = [Double](repeating: -.infinity, count: options.count)
            var link = [Int](repeating: -1, count: options.count)
            for (k, frame) in options.enumerated() {
                let onset = Double(curve.value(at: frame))
                if index == 0 {
                    row[k] = onset - penalty(Double(frame) - frames[0], expected: expected)
                } else {
                    for (j, previous) in candidates[index - 1].enumerated() {
                        let total = scores[index - 1][j] - penalty(Double(frame - previous), expected: expected)
                        if total > row[k] {
                            row[k] = total
                            link[k] = j
                        }
                    }
                    row[k] += onset
                }
            }
            scores.append(row)
            links.append(link)
        }
        let lastExpected = frames[frames.count - 1] - frames[frames.count - 2]
        var bestK = 0, bestTotal = -Double.infinity
        for (k, frame) in candidates[candidates.count - 1].enumerated() {
            let total = scores[scores.count - 1][k] - penalty(frames[frames.count - 1] - Double(frame), expected: lastExpected)
            if total > bestTotal {
                bestTotal = total
                bestK = k
            }
        }
        var picked = [Int](repeating: 0, count: candidates.count)
        var k = bestK
        for index in stride(from: candidates.count - 1, through: 0, by: -1) {
            picked[index] = candidates[index][k]
            k = links[index][k]
        }
        let times = picked.map { curve.seconds(atFrame: Double($0) + curve.subframeOffset(at: $0)) }
        return (times, bestTotal / Double(ideal.count + 1))
    }

    /// Beats stepping on from a fixed beat, one period at a time, up to
    /// (and not including) `limit`. Refined steps move to the strongest
    /// onset near where the next beat should be, so they follow drift;
    /// through a short quiet stretch they keep the period. Stepping stops
    /// where the music does: after `silentBeats` steps in a row with no
    /// onset, which are dropped, so a drawn edge past the end of the song
    /// doesn't fill silence with beats.
    static func stepping(from time: Double, period: Double, direction: Double, limit: Double, curve: OnsetCurve, refine: Bool) -> [Double] {
        guard period > 0 else { return [] }
        var times: [Double] = []
        var previous = time
        var silent = 0
        // Exact steps are counted from the anchor, so they don't add up rounding.
        var step = 1.0
        let reach = period * steadyReach * curve.framesPerSecond
        while times.count < 100_000 {
            var next = refine ? previous + direction * period : time + direction * period * step
            let found = curve.peak(near: curve.frame(atSeconds: next), reach: refine ? reach : max(1, 0.006 * curve.framesPerSecond))
            if refine, found.strength >= weakOnset {
                let moved = curve.seconds(atFrame: found.frame)
                if abs(moved - previous) > period * 0.5 { next = moved }
            }
            if direction > 0 ? next >= limit : next < limit {
                // Up to the edge, but not into silence.
                times.removeLast(silent)
                break
            }
            silent = found.strength >= weakOnset ? 0 : silent + 1
            if silent >= silentBeats {
                times.removeLast(silent - 1)
                break
            }
            times.append(next)
            previous = next
            step += 1
        }
        return times
    }

    /// See `stepping`: a measure of four.
    static let silentBeats = 4

    // MARK: Onset timing

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
            let peak = curve.peak(near: curve.frame(atSeconds: time), reach: reach)
            guard peak.strength >= weakOnset else { return nil }
            return time - curve.seconds(atFrame: peak.frame)
        }.sorted()
        var moved = curve
        moved.start += leads.isEmpty ? onsetLead : min(max(leads[leads.count / 2], -0.05), 0.05)
        return moved
    }

    // MARK: Helpers

    /// Pinned beats in runs of consecutive beats, such as a marked measure:
    /// split wherever a gap is over twice the typical one.
    static func measureRuns(_ times: [Double]) -> [[Double]] {
        guard let typical = zip(times, times.dropFirst()).map({ $1 - $0 }).min(), typical > 0 else {
            return times.isEmpty ? [] : [times]
        }
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

    /// `seconds` on the nearest sample at `sampleRate`.
    static func time(_ seconds: Double, sampleRate: Double) -> CMTime {
        let rate = Int32(max(1, min(sampleRate.rounded(), Double(Int32.max))))
        return CMTime(value: Int64((seconds * Double(rate)).rounded()), timescale: rate)
    }
}
