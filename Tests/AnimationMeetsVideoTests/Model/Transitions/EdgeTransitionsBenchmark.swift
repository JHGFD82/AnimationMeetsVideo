import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Times what a clip's transitions cost per frame drawn: `effect(at:)` and
/// `transitionFrame(at:)` over every frame of a ten second clip at 30 fps
/// with a cube in and a wipe out, and `TransitionFrame.key` for each frame
/// the cube makes, as composition planning reads it. Prints the best of
/// several rounds in nanoseconds per call; nothing is asserted, since
/// timings vary too much from machine to machine for CI.
///
/// Runs only with `TRANSITION_BENCHMARK` set. Release timings are the
/// ones that matter:
///
///     swift build -c release -Xswiftc -enable-testing --build-tests
///     TRANSITION_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing \
///         --skip-build --filter EdgeTransitionsBenchmark
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TRANSITION_BENCHMARK"] != nil))
struct EdgeTransitionsBenchmark {
    private static let rounds = 30
    /// Passes over the clip's frames in each round.
    private static let passes = 200

    /// The fastest round of `body`, which makes `calls` calls, in
    /// nanoseconds per call.
    private func best(calls: Int, _ body: () -> Int) -> (nanoseconds: Double, checksum: Int) {
        let clock = ContinuousClock()
        var fastest = Duration.seconds(1_000)
        var checksum = 0
        for _ in 0..<Self.rounds {
            let elapsed = clock.measure { checksum &+= body() }
            fastest = min(fastest, elapsed)
        }
        let nanoseconds = Double(fastest.components.seconds) * 1e9 + Double(fastest.components.attoseconds) / 1e9
        return (nanoseconds / Double(calls), checksum)
    }

    @Test func aCubeInAndAWipeOut() throws {
        var clip = TimelineClip(
            source: .media(UUID()), startOffset: CMTime(value: 300, timescale: 30),
            trimStart: .zero, trimEnd: CMTime(value: 300, timescale: 30)
        )
        clip.transitionIn = ClipTransition(kind: .cube, duration: CMTime(value: 2, timescale: 1), curve: TransitionCurve(preset: .easyEase))
        clip.transitionOut = ClipTransition(kind: .wipe, duration: CMTime(value: 2, timescale: 1), options: TransitionOptions(direction: .left))
        let edges = try #require(EdgeTransitions(clip: clip, frameSize: CGSize(width: 1920, height: 1080)))
        let times = (0..<300).map { CMTime(value: 300 + Int64($0), timescale: 30) }
        let frames = times.compactMap { edges.transitionFrame(at: $0) }

        let effect = best(calls: times.count * Self.passes) {
            var sum = 0
            for _ in 0..<Self.passes {
                for time in times { sum &+= Int(edges.effect(at: time).opacity * 1000) }
            }
            return sum
        }
        let transitionFrame = best(calls: times.count * Self.passes) {
            var sum = 0
            for _ in 0..<Self.passes {
                for time in times where edges.transitionFrame(at: time) != nil { sum &+= 1 }
            }
            return sum
        }
        let key = best(calls: frames.count * Self.passes / 10) {
            var sum = 0
            for _ in 0..<(Self.passes / 10) {
                for frame in frames { sum &+= frame.key.utf8.count }
            }
            return sum
        }

        print("""
        EdgeTransitionsBenchmark, \(times.count) frames, \(frames.count) of them a cube:
          effect(at:)           \(String(format: "%8.1f", effect.nanoseconds)) ns per frame
          transitionFrame(at:)  \(String(format: "%8.1f", transitionFrame.nanoseconds)) ns per frame
          TransitionFrame.key   \(String(format: "%8.1f", key.nanoseconds)) ns per key
          TransitionFrame stride \(MemoryLayout<TransitionFrame>.stride) bytes
          (checksums \(effect.checksum) \(transitionFrame.checksum) \(key.checksum))
        """)
    }
}
