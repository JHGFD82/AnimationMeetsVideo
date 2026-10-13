import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct FFTTests {
    @Test func crossCorrelationMatchesDirectComputation() {
        let x: [Double] = [1, 2, -1, 3, 0.5]
        let y: [Double] = [2, -1, 4, 1, 0, 2, -3]
        let fast = AudioAlignment.crossCorrelation(x, y)
        #expect(fast.count == x.count + y.count - 1)
        for index in fast.indices {
            let lag = index - (x.count - 1)
            var direct = 0.0
            for i in x.indices where y.indices.contains(i + lag) { direct += x[i] * y[i + lag] }
            #expect(abs(fast[index] - direct) < 1e-9)
        }
    }
}

@Suite struct AudioAlignmentTests {
    /// A deterministic, irregular loudness pattern.
    private func pattern(count: Int) -> [UInt8] {
        var state: UInt64 = 12345
        var levels: [UInt8] = []
        var current = 100.0
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let step = Double(Int64(bitPattern: state >> 33) % 41) - 20
            current = min(max(current + step, 0), 255)
            levels.append(UInt8(current))
        }
        return levels
    }

    @Test func findsAnOffsetWhenTheNewFileStartsLater() throws {
        let long = pattern(count: 6000)
        let reference = AudioEnvelope(startWindow: 0, levels: Array(long[0..<5000]))
        let candidate = AudioEnvelope(startWindow: 0, levels: Array(long[120..<5500]))
        // Content at time t in the reference is at t - 1.20 s in the candidate.
        let found = try #require(AudioAlignment.suggest(reference: reference, candidate: candidate))
        #expect(found.method == .audio)
        #expect(abs(found.offset.seconds - -1.2) < 0.0001)
        #expect(found.isConfident)
    }

    @Test func findsAnOffsetWhenTheNewFileHasLeadingSilence() throws {
        let base = pattern(count: 4000)
        let reference = AudioEnvelope(startWindow: 0, levels: base)
        let candidate = AudioEnvelope(startWindow: 0, levels: [UInt8](repeating: 0, count: 250) + base)
        let found = try #require(AudioAlignment.suggest(reference: reference, candidate: candidate))
        #expect(abs(found.offset.seconds - 2.5) < 0.0001)
    }

    @Test func startWindowsShiftTheOffset() throws {
        let base = pattern(count: 3000)
        let reference = AudioEnvelope(startWindow: 0, levels: base)
        let candidate = AudioEnvelope(startWindow: 40, levels: base)
        let found = try #require(AudioAlignment.suggest(reference: reference, candidate: candidate))
        #expect(abs(found.offset.seconds - 0.4) < 0.0001)
    }

    @Test func identicalEnvelopesGiveZero() throws {
        let base = pattern(count: 3000)
        let envelope = AudioEnvelope(startWindow: 0, levels: base)
        let found = try #require(AudioAlignment.suggest(reference: envelope, candidate: envelope))
        #expect(found.offset.seconds == 0)
        #expect(found.confidence > 0.5)
    }

    @Test func unrelatedAudioIsNotConfident() {
        let reference = AudioEnvelope(startWindow: 0, levels: pattern(count: 3000))
        var other: [UInt8] = []
        var state: UInt64 = 999
        for _ in 0..<3000 {
            state = state &* 2862933555777941757 &+ 3037000493
            other.append(UInt8(truncatingIfNeeded: state >> 40))
        }
        let candidate = AudioEnvelope(startWindow: 0, levels: other)
        let found = AudioAlignment.suggest(reference: reference, candidate: candidate)
        #expect(found == nil || !found!.isConfident)
    }

    @Test func silenceCannotBeAligned() {
        let silent = AudioEnvelope(startWindow: 0, levels: [UInt8](repeating: 0, count: 3000))
        #expect(AudioAlignment.suggest(reference: silent, candidate: silent) == nil)
    }
}

@Suite struct CutAlignmentTests {
    private func times(_ seconds: [Double]) -> [CMTime] {
        seconds.map { CMTime(seconds: $0, preferredTimescale: 600) }
    }

    @Test func findsTheOffsetThatMatchesMostCuts() throws {
        let reference = times([2, 5.5, 9, 14, 20, 27])
        // Every reference cut but the first appears 1 s earlier, plus two extra cuts.
        let candidate = times([0.3, 4.5, 8, 13, 19, 26, 40])
        let found = try #require(CutAlignment.suggest(referenceCuts: reference, candidateCuts: candidate))
        #expect(found.method == .cuts)
        #expect(abs(found.offset.seconds - -1.0) < 0.01)
    }

    @Test func toleratesSmallJitter() throws {
        let reference = times([1, 4, 8, 15, 21])
        let candidate = times([3.02, 6.0, 10.01, 17.0, 23.03])
        let found = try #require(CutAlignment.suggest(referenceCuts: reference, candidateCuts: candidate))
        #expect(abs(found.offset.seconds - 2.0) < 0.05)
        #expect(found.confidence == 1)
    }

    @Test func tooFewMatchesGivesNothing() {
        let reference = times([1, 4, 8, 15, 21])
        let candidate = times([2.5, 6.1, 9.9, 30, 33.3])
        #expect(CutAlignment.suggest(referenceCuts: reference, candidateCuts: candidate) == nil)
    }

    @Test func needsEnoughCuts() {
        #expect(CutAlignment.suggest(referenceCuts: times([1, 2]), candidateCuts: times([1, 2])) == nil)
    }
}
