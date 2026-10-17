import CoreMedia
import Foundation

/// Hands decoded audio on at the positions its timestamps give. The
/// reader's buffers normally follow each other exactly, but if one were
/// dropped, or timestamps jumped or overlapped, joining them end to end
/// would shift every beat after that point away from the asset's time.
struct TimedSamples {
    /// A timestamp within this many samples of where a buffer is expected
    /// is on time: the difference is rounding between timescales.
    static let tolerance: Int64 = 2

    /// The most silence a gap is filled with. A timestamp further ahead
    /// than this is damage rather than a gap.
    let longestGap: Int64
    /// Samples per second of the audio handed in.
    let sampleRate: Double
    /// Where the samples go, in order, gaps filled with zeros. What it
    /// throws (a cancellation) stops `append` at once.
    let feed: (UnsafeBufferPointer<Float>) throws -> Void
    /// The asset-time position, in samples at `sampleRate`, of
    /// the first sample handed on: the first buffer that contributes any,
    /// never an empty one. Nil until then.
    private(set) var origin: Int64?
    /// Samples handed on so far, gap fill included.
    private(set) var fed: Int64 = 0

    init(longestGap: Int64, sampleRate: Double = BeatDetector.sampleRate, feed: @escaping (UnsafeBufferPointer<Float>) throws -> Void) {
        self.longestGap = longestGap
        self.sampleRate = sampleRate
        self.feed = feed
    }

    /// Places one buffer's samples. A buffer later than expected has the
    /// gap before it filled with silence; one earlier than expected has the
    /// part already covered dropped, and is dropped whole if all of it is.
    /// A buffer without a usable timestamp follows on from the one before.
    /// Throws `DetectionError.malformedAudio` for a jump past `longestGap`.
    mutating func append(_ samples: [Float], at presentation: CMTime) throws {
        guard !samples.isEmpty else { return }
        let position = try samplePosition(of: presentation)
        guard let origin else {
            origin = position ?? 0
            try hand(samples[...])
            return
        }
        guard let position else {
            try hand(samples[...])
            return
        }
        let (expected, endOverflow) = origin.addingReportingOverflow(fed)
        let (offset, offsetOverflow) = position.subtractingReportingOverflow(expected)
        guard !endOverflow, !offsetOverflow else {
            throw BeatDetector.DetectionError.malformedAudio("a buffer's timestamp is out of range")
        }
        if offset > Self.tolerance {
            guard offset <= longestGap else {
                let seconds = Double(offset) / sampleRate
                throw BeatDetector.DetectionError.malformedAudio("a buffer's timestamp jumps \(Int(seconds)) seconds ahead")
            }
            try handSilence(offset)
            try hand(samples[...])
        } else if offset < -Self.tolerance {
            let overlap = -offset
            guard overlap < Int64(samples.count) else { return }
            try hand(samples[Int(overlap)...])
        } else {
            try hand(samples[...])
        }
    }

    /// The timestamp in samples, or nil if there is none. Throws for a
    /// numeric timestamp too far out to count in samples.
    private func samplePosition(of time: CMTime) throws -> Int64? {
        guard time.isNumeric, time.timescale > 0 else { return nil }
        let rate = Int32(sampleRate)
        let converted = time.convertScale(rate, method: .roundHalfAwayFromZero)
        // An overflowing conversion comes back as an infinity, or clamped.
        guard converted.isNumeric, converted.timescale == rate,
              abs(converted.seconds - time.seconds) < 1
        else {
            throw BeatDetector.DetectionError.malformedAudio("a buffer's timestamp is out of range")
        }
        return converted.value
    }

    private mutating func hand(_ samples: ArraySlice<Float>) throws {
        try samples.withUnsafeBufferPointer { try feed($0) }
        fed += Int64(samples.count)
    }

    /// In chunks, so a long gap can be cancelled part way.
    private mutating func handSilence(_ count: Int64) throws {
        let chunk = [Float](repeating: 0, count: Int(min(count, 1 << 16)))
        var left = count
        while left > 0 {
            let length = Int(min(left, Int64(chunk.count)))
            try hand(chunk[..<length])
            left -= Int64(length)
        }
    }
}
