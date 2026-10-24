import Accelerate
import Foundation

/// Finds the tempo of an onset curve and places beats on it, after Ellis,
/// "Beat Tracking by Dynamic Programming", extended to a tempo that changes:
/// the period is measured over short stretches, joined into one path that
/// may glide or jump, and the beats are the string that lands on strong
/// onsets while keeping close to the period at each moment.
enum BeatTracker {
    struct Result {
        /// Envelope frame of each beat.
        var frames: [Int]
        /// The typical tempo of these beats (see `beatsPerMinute(ofFrames:framesPerSecond:)`).
        var beatsPerMinute: Double
        /// Why the beats were taken for a steady pulse.
        var confidence: Confidence
    }

    static let minimumBPM = 60.0
    static let maximumBPM = 200.0
    /// Tempo guesses are pulled toward this, which settles the choice
    /// between a tempo and its double or half.
    static let preferredBPM = 120.0
    /// How strongly beats are held to the tempo versus chasing onsets.
    static let tightness = 100.0
    /// Shorter than this there isn't enough to tell a tempo from noise.
    static let minimumSeconds = 4.0
    /// The stretch each local tempo is measured over, and how far apart
    /// the stretches start. Long enough to hold several beats at the
    /// slowest tempo, short enough to follow a ramp.
    static let tempoWindowSeconds = 8.0
    static let tempoHopSeconds = 1.0
    /// What a change of tempo between neighbouring stretches costs, per
    /// squared octave, so a gradual ramp is cheap to follow.
    static let tempoGlide = 40.0
    /// The most a change between neighbouring stretches costs. A sudden
    /// change, or a flip to double or half tempo, is taken only once a few
    /// seconds of music are better explained by it.
    static let tempoJump = 2.5
    /// A change between neighbouring stretches bigger than this, in
    /// octaves (about 7%), is a jump rather than part of a ramp.
    static let suddenChange = 0.1

    /// The tracker was given something that isn't an onset curve.
    enum InputError: LocalizedError, Equatable {
        /// The frame rate isn't a finite, positive number.
        case invalidFrameRate(Double)
        /// The value at this frame isn't finite and nonnegative.
        case invalidOnset(frame: Int)

        var errorDescription: String? {
            switch self {
            case .invalidFrameRate(let rate): "The onset curve's frame rate (\(rate)) isn't a positive number."
            case .invalidOnset(let frame): "The onset curve has a value at frame \(frame) that isn't a number."
            }
        }
    }

    /// The beats of an onset curve, or nil when it holds no steady beat
    /// (including a curve too short to tell, and one whose beats fall short
    /// of `Confidence.isSteadyBeat`). Throws `InputError`, before
    /// doing any work, when the frame rate isn't finite and positive or a
    /// value isn't finite and nonnegative: those would trap in the
    /// conversions to frame counts or poison every score.
    ///
    /// `checkpoint` is called every so often through the work with roughly
    /// how much of it is done, in 0..<1 and never decreasing; what it throws,
    /// such as `CancellationError`, stops tracking and is rethrown.
    static func track(
        envelope raw: [Float], framesPerSecond: Double, checkpoint: (Double) throws -> Void = { _ in }
    ) throws -> Result? {
        guard framesPerSecond.isFinite, framesPerSecond > 0 else {
            throw InputError.invalidFrameRate(framesPerSecond)
        }
        if let bad = raw.firstIndex(where: { !$0.isFinite || $0 < 0 }) {
            throw InputError.invalidOnset(frame: bad)
        }
        // A long enough curve also bounds the frame rate by its length, so
        // the frame counts worked out from it below fit in an Int.
        guard Double(raw.count) / framesPerSecond >= minimumSeconds,
              let onsets = prepared(raw, framesPerSecond: framesPerSecond),
              let periods = try periods(of: onsets, framesPerSecond: framesPerSecond, checkpoint: checkpoint)
        else {
            return nil
        }
        let frames = try chain(onsets, periods: periods, checkpoint: checkpoint)
        let kept = trimmed(frames, onsets: onsets)
        guard let tempo = beatsPerMinute(ofFrames: kept, framesPerSecond: framesPerSecond) else { return nil }
        // The chain lays a regular string of beats over any sound at all,
        // noise and speech included, so it is kept only if it is a pulse.
        let confidence = confidence(of: kept, onsets: onsets, periodicity: periods.periodicity)
        guard confidence.isSteadyBeat else { return nil }
        return Result(frames: kept, beatsPerMinute: tempo, confidence: confidence)
    }

    /// How sure the tracker is that the beats are a real pulse rather than
    /// a regular chain laid over sound with none.
    ///
    /// The thresholds were set from whole files, as the app analyzes them:
    /// full mixes and the instrument, drum and vocal stems of several songs,
    /// a crowd track, a stem that is only dither, a spoken recording and a
    /// feature film's dialogue; and from synthetic material (click tracks,
    /// drum patterns loud and quiet, white and wandering noise, speech-like
    /// syllables, isolated and random clicks). Speech, crowd, noise and
    /// dither scored a periodicity of at most 0.15, vocal stems up to 0.26,
    /// and rhythmic material at least 0.32 (a pop song with a busy vocal
    /// over a light rhythm section); full mixes and drums mostly above 0.8.
    /// So a vocal stem on its own may get beats, while dialogue doesn't.
    struct Confidence: Equatable {
        /// The onset curve's periodicity contrast, the median over the
        /// stretches that aren't silent. For each stretch it is how much
        /// more the curve correlates with itself one, two or four periods
        /// on (the best of the three, since a bar repeats more exactly than
        /// a beat) than at a typical lag in the tempo range. About 0 for
        /// speech and noise, which correlate as much at any lag; around 1
        /// for a pulse that repeats exactly.
        var periodicity: Double
        /// How many gaps between consecutive beats have an onset at both ends.
        var supportedIntervals: Int
        /// The onset strength at the beats over that at the same beats moved
        /// a quarter, half and three quarters of the way to the next one:
        /// near 1.5 for noise, where the chain only finds the local bumps.
        var agreement: Double
        /// The beats, for `supportedShare`.
        var intervals: Int

        /// The share of intervals with an onset at both ends.
        var supportedShare: Double { intervals > 0 ? Double(supportedIntervals) / Double(intervals) : 0 }

        static let minimumPeriodicity = 0.25
        /// Above this periodicity agreement isn't asked for: steady
        /// sixteenth-note hi-hats are as strong between the beats as on them.
        static let clearPeriodicity = 0.5
        static let minimumAgreement = 2.0
        static let minimumSupportedShare = 0.25
        /// A beat needs a few bars' worth of evidence, not two transients.
        static let minimumSupportedIntervals = 4

        /// The onsets repeat at the tempo, the beats sit on onsets rather than
        /// between them (unless the repetition is clear anyway), and they do
        /// so across several intervals.
        var isSteadyBeat: Bool {
            periodicity >= Self.minimumPeriodicity
                && (agreement >= Self.minimumAgreement || periodicity >= Self.clearPeriodicity)
                && supportedShare >= Self.minimumSupportedShare && supportedIntervals >= Self.minimumSupportedIntervals
        }
    }

    /// The largest onset within this many frames of a beat counts as its
    /// onset; peaks are a frame or two wide and beats land within a frame.
    private static let onsetReach = 2
    /// An onset counts as supporting a beat at this many times the curve's
    /// RMS, which `prepared` scales to 1.
    private static let supportLevel: Float = 1

    private static func confidence(of frames: [Int], onsets: [Float], periodicity: Double) -> Confidence {
        func onset(near frame: Int) -> Float {
            let low = max(0, frame - onsetReach), high = min(onsets.count - 1, frame + onsetReach)
            guard low <= high else { return 0 }
            return onsets[low...high].max() ?? 0
        }
        let supported = frames.map { onset(near: $0) >= supportLevel }
        let intervals = zip(supported, supported.dropFirst()).filter { $0 && $1 }.count

        var onBeat = 0.0, offBeat = 0.0
        for (beat, next) in zip(frames, frames.dropFirst()) {
            onBeat += Double(onset(near: beat))
            let gap = Double(next - beat)
            offBeat += [0.25, 0.5, 0.75].map { Double(onset(near: beat + Int((gap * $0).rounded()))) }.reduce(0, +) / 3
        }
        let agreement = offBeat > 0 ? onBeat / offBeat : (onBeat > 0 ? .infinity : 0)
        return Confidence(
            periodicity: periodicity, supportedIntervals: intervals, agreement: agreement, intervals: max(0, frames.count - 1)
        )
    }

    /// The tempo the beats themselves keep, from the median of the gaps
    /// between consecutive beats (the mean of the middle two for an even
    /// count). It describes the markers, wherever the chain followed the
    /// alternative period or strayed from the estimate. The median ignores
    /// a few missed or doubled beats, and for a tempo that changes it is
    /// the tempo held for the most beats. Nil with no positive gap.
    static func beatsPerMinute(ofFrames frames: [Int], framesPerSecond: Double) -> Double? {
        let gaps = zip(frames.dropFirst(), frames).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return nil }
        let middle = gaps.count / 2
        let median = gaps.count.isMultiple(of: 2)
            ? (Double(gaps[middle - 1]) + Double(gaps[middle])) / 2
            : Double(gaps[middle])
        return 60 * framesPerSecond / median
    }

    /// Keeps only what stands out from the surrounding second, then scales
    /// to unit spread so the settings above mean the same for any loudness.
    /// Nil for a curve with nothing standing out.
    static func prepared(_ raw: [Float], framesPerSecond: Double) -> [Float]? {
        let radius = max(1, Int(framesPerSecond / 2))
        var prefix = [Double](repeating: 0, count: raw.count + 1)
        for i in raw.indices { prefix[i + 1] = prefix[i] + Double(raw[i]) }
        var onsets = [Float](repeating: 0, count: raw.count)
        for i in raw.indices {
            let low = max(0, i - radius), high = min(raw.count, i + radius + 1)
            let mean = (prefix[high] - prefix[low]) / Double(high - low)
            onsets[i] = max(0, raw[i] - Float(mean))
        }
        // In Double, so values near Float's limit don't overflow the sum.
        let sumOfSquares = onsets.reduce(0.0) { $0 + Double($1) * Double($1) }
        let spread = (sumOfSquares / Double(onsets.count)).squareRoot()
        guard spread > 1e-6 else { return nil }
        return onsets.map { Float(Double($0) / spread) }
    }

    /// The beat period in frames (fractional) at every frame. Where the
    /// tempo jumps, the frames between the two stretches' centers also get
    /// the period on the other side of the jump, and the beat chain takes
    /// whichever fits, so the onsets decide exactly where the change falls.
    struct Periods {
        var main: [Double]
        var alternative: [Double?]
        /// See `Confidence.periodicity`.
        var periodicity: Double
    }

    /// The periods at every frame (see `Periods`). Each stretch
    /// of `tempoWindowSeconds` scores every candidate period by its
    /// autocorrelation, weighted toward everyday tempos; a Viterbi pass
    /// then picks one period per stretch, trading those scores against
    /// the cost of changing tempo, and the result is interpolated between
    /// the stretches' centers.
    private static func periods(
        of onsets: [Float], framesPerSecond: Double, checkpoint: (Double) throws -> Void
    ) throws -> Periods? {
        let shortest = max(2, Int((framesPerSecond * 60 / maximumBPM).rounded(.down)))
        let longest = Int((framesPerSecond * 60 / minimumBPM).rounded(.up))
        // At a frame rate this low the whole tempo range is under a frame or two.
        guard shortest < longest, longest + 1 < onsets.count else { return nil }

        let length = min(onsets.count, max(Int(tempoWindowSeconds * framesPerSecond), 2 * (longest + 2)))
        let hop = max(1, Int(tempoHopSeconds * framesPerSecond))
        var starts = Array(stride(from: 0, to: onsets.count - length, by: hop))
        starts.append(onsets.count - length)

        let lags = Array(shortest...(longest + 1))
        let states = lags.count - 1
        let preferred = framesPerSecond * 60 / preferredBPM
        let weights = lags.map { lag -> Double in
            let octaves = log2(Double(lag) / preferred) / 1.4
            return exp(-0.5 * octaves * octaves)
        }

        // Onset peaks are a frame or two wide, so a period between two whole
        // frames splits its match across both lags and loses to a slower
        // tempo whose period happens to be whole. Blurring the curve a
        // little, for measuring tempo only, lets every period match fully.
        let blurred = blurred(onsets)

        // Each stretch's scores, scaled so its best is 1. A silent stretch
        // scores nothing, and the tempo carries through it.
        var scores: [[Double]] = []
        var anyEvidence = false
        try blurred.withUnsafeBufferPointer { buffer in
            for (index, start) in starts.enumerated() {
                // Scoring the stretches is about half the work, the Viterbi
                // pass a tenth and the beat chain the rest.
                try checkpoint(0.5 * Double(index) / Double(starts.count))
                var row = lags.indices.map { index -> Double in
                    let lag = lags[index]
                    let overlap = length - lag
                    guard overlap > 0 else { return 0 }
                    var sum: Float = 0
                    vDSP_dotpr(buffer.baseAddress! + start, 1, buffer.baseAddress! + start + lag, 1, &sum, vDSP_Length(overlap))
                    return Double(sum) / Double(overlap) * weights[index]
                }
                let best = row[..<states].max() ?? 0
                if best > 0 {
                    anyEvidence = true
                    row = row.map { max(0, $0) / best }
                } else {
                    row = row.map { _ in 0 }
                }
                scores.append(row)
            }
        }
        guard anyEvidence else { return nil }

        // Viterbi over the candidate periods.
        let logLags = lags.map { log2(Double($0)) }
        var total = Array(scores[0][..<states])
        var backlinks: [[Int]] = []
        for (index, row) in scores.dropFirst().enumerated() {
            try checkpoint(0.5 + 0.1 * Double(index) / Double(scores.count))
            var next = [Double](repeating: -.infinity, count: states)
            var links = [Int](repeating: 0, count: states)
            for state in 0..<states {
                var best = -Double.infinity
                for previous in 0..<states {
                    let change = logLags[state] - logLags[previous]
                    let candidate = total[previous] - min(tempoGlide * change * change, tempoJump)
                    if candidate > best {
                        best = candidate
                        links[state] = previous
                    }
                }
                next[state] = best + row[state]
            }
            total = next
            backlinks.append(links)
        }
        var path = [Int](repeating: 0, count: scores.count)
        path[path.count - 1] = total.indices.max { total[$0] < total[$1] } ?? 0
        for index in stride(from: path.count - 1, to: 0, by: -1) {
            path[index - 1] = backlinks[index - 1][path[index]]
        }

        // Refine each stretch's period between frames: at 86 frames a
        // second, one frame is several BPM.
        let periods = path.indices.map { index -> Double in
            let state = path[index], row = scores[index]
            guard state > 0 else { return Double(lags[state]) }
            let left = row[state - 1], middle = row[state], right = row[state + 1]
            let curve = left - 2 * middle + right
            guard curve < 0 else { return Double(lags[state]) }
            return Double(lags[state]) + (0.5 * (left - right) / curve).clamped(between: -0.5, and: 0.5)
        }

        let centers = starts.map { Double($0) + Double(length) / 2 }
        var perFrame = [Double](repeating: periods[0], count: onsets.count)
        var alternative = [Double?](repeating: nil, count: onsets.count)
        var segment = 0
        for frame in onsets.indices {
            let position = Double(frame)
            while segment + 1 < centers.count, centers[segment + 1] <= position { segment += 1 }
            if position <= centers[0] {
                perFrame[frame] = periods[0]
            } else if segment + 1 >= centers.count {
                perFrame[frame] = periods[periods.count - 1]
            } else {
                let fraction = (position - centers[segment]) / (centers[segment + 1] - centers[segment])
                let before = periods[segment], after = periods[segment + 1]
                if abs(log2(after / before)) > suddenChange {
                    // A jump, not a glide: easing into it would put beats between the two tempos.
                    perFrame[frame] = fraction < 0.5 ? before : after
                } else {
                    perFrame[frame] = before + fraction * (after - before)
                }
            }
        }
        // The change can fall anywhere the two stretches overlap, so the
        // chain may use either period from a stretch before the jump's
        // midpoint to a stretch after it.
        for segment in 0..<max(0, centers.count - 1) {
            let before = periods[segment], after = periods[segment + 1]
            guard abs(log2(after / before)) > suddenChange else { continue }
            let middle = (centers[segment] + centers[segment + 1]) / 2
            let reach = Double(hop) * 1.5
            let low = max(0, Int(middle - reach)), high = min(onsets.count - 1, Int(middle + reach))
            guard low <= high else { continue }
            for frame in low...high {
                alternative[frame] = Double(frame) < middle ? after : before
            }
        }
        let periodicity = Self.periodicity(of: blurred, starts: starts, length: length, periods: periods, lags: lags)
        return Periods(main: perFrame, alternative: alternative, periodicity: periodicity)
    }

    /// See `Confidence.periodicity`. `lags` is the tempo range, whose
    /// median coefficient is the baseline; each multiple of the period is
    /// taken at the better of the whole lags either side of it.
    private static func periodicity(of curve: [Float], starts: [Int], length: Int, periods: [Double], lags: [Int]) -> Double {
        var contrasts: [Double] = []
        curve.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            for (start, period) in zip(starts, periods) {
                var mean: Float = 0, meanSquare: Float = 0
                vDSP_meanv(base + start, 1, &mean, vDSP_Length(length))
                vDSP_measqv(base + start, 1, &meanSquare, vDSP_Length(length))
                let variance = Double(meanSquare) - Double(mean) * Double(mean)
                guard variance > 1e-9 else { continue }
                /// The autocorrelation coefficient at `lag`, 0 where too
                /// little of the stretch overlaps to say.
                func coefficient(_ lag: Int) -> Double {
                    let overlap = length - lag
                    guard lag > 0, overlap > length / 4 else { return 0 }
                    var sum: Float = 0
                    vDSP_dotpr(base + start, 1, base + start + lag, 1, &sum, vDSP_Length(overlap))
                    return (Double(sum) / Double(overlap) - Double(mean) * Double(mean)) / variance
                }
                let repeating = [1.0, 2, 4].map { multiple -> Double in
                    let lag = period * multiple
                    return max(coefficient(Int(lag.rounded(.down))), coefficient(Int(lag.rounded(.up))))
                }.max() ?? 0
                let typical = lags.map(coefficient).sorted()
                contrasts.append(repeating - typical[typical.count / 2])
            }
        }
        guard !contrasts.isEmpty else { return 0 }
        return contrasts.sorted()[contrasts.count / 2]
    }

    /// The curve smoothed with a small Gaussian (a deviation of 1.5 frames).
    private static func blurred(_ onsets: [Float]) -> [Float] {
        let kernel: [Float] = (-4...4).map { exp(-Float($0 * $0) / (2 * 1.5 * 1.5)) }
        var result = [Float](repeating: 0, count: onsets.count)
        for index in onsets.indices {
            var total: Float = 0
            for (offset, weight) in kernel.enumerated() {
                let position = index + offset - 4
                guard onsets.indices.contains(position) else { continue }
                total += onsets[position] * weight
            }
            result[index] = total
        }
        return result
    }

    /// Dynamic programming: each frame's best score is its onset strength
    /// plus the best earlier beat, minus a penalty for straying from the
    /// period at that frame.
    private static func chain(_ onsets: [Float], periods: Periods, checkpoint: (Double) throws -> Void) throws -> [Int] {
        let count = onsets.count
        let longestPeriod = max(periods.main.max() ?? 2, periods.alternative.compactMap { $0 }.max() ?? 2)
        let farthestAnywhere = max(2, Int((longestPeriod * 2).rounded()))
        let logGaps = (0...farthestAnywhere).map { log(Double(max($0, 1))) }

        var score = [Double](repeating: 0, count: count)
        var backlink = [Int](repeating: -1, count: count)
        for t in 0..<count {
            if t % 1024 == 0 { try checkpoint(0.6 + 0.4 * Double(t) / Double(count)) }
            let period = periods.main[t]
            let other = periods.alternative[t] ?? period
            let logPeriod = log(period), logOther = log(other)
            let nearest = max(1, Int((min(period, other) / 2).rounded()))
            let farthest = max(nearest + 1, Int((max(period, other) * 2).rounded()))
            var best = 0.0
            var from = -1
            if t - nearest >= 0 {
                for gap in nearest...min(farthest, t) {
                    let stray = min(abs(logGaps[gap] - logPeriod), abs(logGaps[gap] - logOther))
                    let candidate = score[t - gap] - tightness * stray * stray
                    if candidate > best {
                        best = candidate
                        from = t - gap
                    }
                }
            }
            score[t] = Double(onsets[t]) + best
            backlink[t] = from
        }

        let peaks = (1..<(count - 1)).filter { score[$0] >= score[$0 - 1] && score[$0] > score[$0 + 1] }
        guard !peaks.isEmpty else { return [] }
        let sorted = peaks.map { score[$0] }.sorted()
        let threshold = 0.5 * sorted[sorted.count / 2]
        guard let last = peaks.last(where: { score[$0] >= threshold }) else { return [] }

        var frames: [Int] = []
        var cursor = last
        while cursor >= 0 {
            frames.append(cursor)
            cursor = backlink[cursor]
        }
        return frames.reversed()
    }

    /// Drops beats at the start and end that sit on near silence; the chain
    /// keeps stepping at the tempo through quiet stretches.
    private static func trimmed(_ frames: [Int], onsets: [Float]) -> [Int] {
        guard frames.count > 2 else { return frames }
        let strengths = frames.map { Double(onsets[$0]) }
        let weights = [1.0, 2, 3, 2, 1]
        let smoothed = strengths.indices.map { index -> Double in
            var total = 0.0, weightSum = 0.0
            for (offset, weight) in weights.enumerated() {
                let position = index + offset - 2
                guard strengths.indices.contains(position) else { continue }
                total += strengths[position] * weight
                weightSum += weight
            }
            return total / weightSum
        }
        let rms = (smoothed.map { $0 * $0 }.reduce(0, +) / Double(smoothed.count)).squareRoot()
        let threshold = 0.5 * rms
        guard let first = smoothed.firstIndex(where: { $0 >= threshold }),
              let last = smoothed.lastIndex(where: { $0 >= threshold })
        else {
            return []
        }
        return Array(frames[first...last])
    }
}
