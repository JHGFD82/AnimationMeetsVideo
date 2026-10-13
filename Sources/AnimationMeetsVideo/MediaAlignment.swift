import CoreMedia
import Foundation

/// A proposed time offset between an asset's original file and a new one.
/// `offset` is how far later the same moment is in the new file: a moment at
/// time `t` in the original is at `t + offset` in the new file.
struct AlignmentSuggestion: Equatable, Sendable {
    enum Method: String, Sendable { case audio, cuts }

    var offset: CMTime
    var method: Method
    /// 0...1: how clearly the best offset stands out from every other.
    var confidence: Double

    /// Confident enough to offer without a warning.
    static let confidentThreshold = 0.25
    var isConfident: Bool { confidence >= Self.confidentThreshold }
}

enum MediaAlignment {
    /// The best suggestion from what both files offer: audio when both have
    /// it and it matches clearly, otherwise matching cuts.
    static func suggest(
        referenceAudio: AudioEnvelope?, candidateAudio: AudioEnvelope?,
        referenceScores: ChangeScoreTrack?, candidateScores: ChangeScoreTrack?
    ) -> AlignmentSuggestion? {
        var best: AlignmentSuggestion?
        if let referenceAudio, let candidateAudio,
           let found = AudioAlignment.suggest(reference: referenceAudio, candidate: candidateAudio) {
            best = found
            if found.isConfident { return found }
        }
        if let referenceScores, let candidateScores,
           let found = CutAlignment.suggest(reference: referenceScores, candidate: candidateScores) {
            if best == nil || found.confidence > best!.confidence { best = found }
        }
        return best
    }
}

// MARK: - Audio

enum AudioAlignment {
    /// Finds the offset that best lines up two loudness envelopes, by
    /// normalized cross-correlation. Nil when either has no variation or
    /// they share too little time to compare.
    static func suggest(reference: AudioEnvelope, candidate: AudioEnvelope) -> AlignmentSuggestion? {
        let x = centered(reference.levels), y = centered(candidate.levels)
        let nx = x.count, ny = y.count
        guard nx > 1, ny > 1 else { return nil }

        let sumX = prefixSumsOfSquares(x), sumY = prefixSumsOfSquares(y)
        guard sumX[nx] > 0, sumY[ny] > 0 else { return nil }

        let correlation = crossCorrelation(x, y)
        // lag L pairs x[i] with y[i + L]; the table holds L from -(nx-1) to ny-1.
        let minimumOverlap = max(500, min(nx, ny) / 4)
        var scores = [Double](repeating: 0, count: nx + ny - 1)
        for index in scores.indices {
            let lag = index - (nx - 1)
            let from = max(0, -lag), to = min(nx, ny - lag)
            guard to - from >= minimumOverlap else { continue }
            let energyX = sumX[to] - sumX[from]
            let energyY = sumY[to + lag] - sumY[from + lag]
            guard energyX > 1e-9, energyY > 1e-9 else { continue }
            scores[index] = correlation[index] / (energyX * energyY).squareRoot()
        }

        guard let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[bestIndex] > 0 else { return nil }
        let best = scores[bestIndex]
        // The runner-up is the strongest match anywhere clearly elsewhere.
        let neighbourhood = 50
        var runnerUp = 0.0
        for index in scores.indices where abs(index - bestIndex) > neighbourhood {
            runnerUp = max(runnerUp, scores[index])
        }

        let lag = bestIndex - (nx - 1)
        let offsetWindows = Int64(lag) - reference.startWindow + candidate.startWindow
        return AlignmentSuggestion(
            offset: CMTime(value: offsetWindows, timescale: Int32(AudioEnvelope.windowsPerSecond)),
            method: .audio,
            confidence: min(max(best - runnerUp, 0), 1)
        )
    }

    private static func centered(_ levels: [UInt8]) -> [Double] {
        guard !levels.isEmpty else { return [] }
        let mean = levels.reduce(0.0) { $0 + Double($1) } / Double(levels.count)
        return levels.map { Double($0) - mean }
    }

    private static func prefixSumsOfSquares(_ values: [Double]) -> [Double] {
        var sums = [Double](repeating: 0, count: values.count + 1)
        for index in values.indices { sums[index + 1] = sums[index] + values[index] * values[index] }
        return sums
    }

    /// `result[k]` is the sum of `x[i] * y[i + k - (x.count - 1)]`.
    static func crossCorrelation(_ x: [Double], _ y: [Double]) -> [Double] {
        let count = x.count + y.count - 1
        var size = 1
        while size < count { size <<= 1 }

        var xr = [Double](repeating: 0, count: size), xi = [Double](repeating: 0, count: size)
        var yr = [Double](repeating: 0, count: size), yi = [Double](repeating: 0, count: size)
        for index in x.indices { xr[index] = x[index] }
        for index in y.indices { yr[index] = y[index] }
        FFT.transform(&xr, &xi, inverse: false)
        FFT.transform(&yr, &yi, inverse: false)

        // conj(X) * Y
        var pr = [Double](repeating: 0, count: size), pi = [Double](repeating: 0, count: size)
        for index in 0..<size {
            pr[index] = xr[index] * yr[index] + xi[index] * yi[index]
            pi[index] = xr[index] * yi[index] - xi[index] * yr[index]
        }
        FFT.transform(&pr, &pi, inverse: true)

        // Lag L lives at index L mod size.
        var result = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let lag = index - (x.count - 1)
            result[index] = pr[(lag + size) % size]
        }
        return result
    }
}

/// An in-place radix-2 FFT; `count` must be a power of two.
enum FFT {
    static func transform(_ real: inout [Double], _ imaginary: inout [Double], inverse: Bool) {
        let n = real.count
        precondition(n & (n - 1) == 0 && imaginary.count == n, "size must be a power of two")
        guard n > 1 else { return }

        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
        }

        var length = 2
        while length <= n {
            let angle = 2 * Double.pi / Double(length) * (inverse ? 1 : -1)
            let stepR = cos(angle), stepI = sin(angle)
            var start = 0
            while start < n {
                var wr = 1.0, wi = 0.0
                for k in 0..<(length / 2) {
                    let a = start + k, b = a + length / 2
                    let tr = real[b] * wr - imaginary[b] * wi
                    let ti = real[b] * wi + imaginary[b] * wr
                    real[b] = real[a] - tr
                    imaginary[b] = imaginary[a] - ti
                    real[a] += tr
                    imaginary[a] += ti
                    let next = wr * stepR - wi * stepI
                    wi = wr * stepI + wi * stepR
                    wr = next
                }
                start += length
            }
            length <<= 1
        }

        if inverse {
            let scale = 1 / Double(n)
            for index in 0..<n {
                real[index] *= scale
                imaginary[index] *= scale
            }
        }
    }
}

// MARK: - Cuts

enum CutAlignment {
    /// Cuts closer than this to a predicted position count as the same cut.
    static let toleranceSeconds = 0.05
    static let minimumMatches = 3
    static let cutSensitivity = ReferenceThumbnailCapture.cutSensitivity

    /// Finds the offset at which the most cuts of the two files coincide.
    static func suggest(reference: ChangeScoreTrack, candidate: ChangeScoreTrack) -> AlignmentSuggestion? {
        suggest(
            referenceCuts: SceneDetector.autoCuts(in: reference, defaultSensitivity: cutSensitivity),
            candidateCuts: SceneDetector.autoCuts(in: candidate, defaultSensitivity: cutSensitivity)
        )
    }

    static func suggest(referenceCuts: [CMTime], candidateCuts: [CMTime]) -> AlignmentSuggestion? {
        guard referenceCuts.count >= minimumMatches, candidateCuts.count >= minimumMatches else { return nil }

        struct Pair {
            var seconds: Double
            var referenceIndex: Int
            var offset: CMTime
        }
        var pairs: [Pair] = []
        pairs.reserveCapacity(referenceCuts.count * candidateCuts.count)
        for (r, reference) in referenceCuts.enumerated() {
            for candidate in candidateCuts {
                let offset = CMTimeSubtract(candidate, reference)
                pairs.append(Pair(seconds: offset.seconds, referenceIndex: r, offset: offset))
            }
        }
        pairs.sort { $0.seconds < $1.seconds }

        // Slide a window along the sorted offsets and count how many
        // different reference cuts agree on one offset.
        var bestStart = 0, bestEnd = 0, bestCount = 0
        var counts: [Int: Int] = [:]
        var start = 0
        for end in pairs.indices {
            counts[pairs[end].referenceIndex, default: 0] += 1
            while pairs[end].seconds - pairs[start].seconds > 2 * toleranceSeconds {
                counts[pairs[start].referenceIndex, default: 1] -= 1
                if counts[pairs[start].referenceIndex] == 0 { counts[pairs[start].referenceIndex] = nil }
                start += 1
            }
            if counts.count > bestCount {
                bestCount = counts.count
                bestStart = start
                bestEnd = end
            }
        }
        guard bestCount >= minimumMatches else { return nil }

        let window = pairs[bestStart...bestEnd]
        let middle = window.sorted { $0.seconds < $1.seconds }[window.count / 2].offset
        let share = Double(bestCount) / Double(min(referenceCuts.count, candidateCuts.count))
        return AlignmentSuggestion(offset: middle, method: .cuts, confidence: min(max(share, 0), 1))
    }
}
