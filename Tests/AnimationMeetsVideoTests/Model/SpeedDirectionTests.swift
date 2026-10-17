import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A speed curve that passes zero can't turn the clip around: past zero it
/// is held at 1% the clip's own way, not played at its size the other way.
@Suite struct SpeedDirectionTests {
    /// A linear ramp from `from` to `to` over one second.
    private func ramp(_ from: Double, _ to: Double) -> AnimatedValue<Double> {
        AnimatedValue(from, keyframes: [
            Keyframe(time: .zero, value: from),
            Keyframe(time: CMTime(value: 1, timescale: 1), value: to),
        ])
    }

    /// The timeline seconds the ramp's one second of source takes, summed
    /// finely with the speed held at 1% to 10000% along `sign`.
    private func reference(_ from: Double, _ to: Double, sign: Double) -> Double {
        let steps = 200_000
        var total = 0.0
        for index in 0..<steps {
            let t = (Double(index) + 0.5) / Double(steps)
            let along = (from + (to - from) * t) * sign
            total += 100 / min(max(along, 1), 10_000) / Double(steps)
        }
        return total
    }

    @Test func aForwardRampPastZeroIsHeldAtOnePercent() {
        let speed = ramp(100, -50)
        #expect(ClipTime.playedSize(-50, reversed: false) == 1)
        let got = SpeedIntegral.of(speed).length(from: 0, to: 1)
        #expect(abs(got - reference(100, -50, sign: 1)) < 1e-4)
    }

    @Test func aBackwardRampPastZeroIsHeldAtOnePercentBackwards() {
        let speed = ramp(-100, 50)
        #expect(ClipTime.playedSize(50, reversed: true) == 1)
        #expect(ClipTime.playedSize(-250, reversed: true) == 250)
        let got = SpeedIntegral.of(speed).length(from: 0, to: 1)
        #expect(abs(got - reference(-100, 50, sign: -1)) < 1e-4)
    }

    @Test func aClipReadsItsSpeedAlongItsDirection() {
        var clip = TimelineClip(
            source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 1, timescale: 1)
        )
        clip.time.speed = ramp(-100, 50)
        #expect(clip.isReversed)
        // At the end the curve has gone past zero: held at 1%, backwards.
        #expect(clip.speed(atSource: CMTime(value: 1, timescale: 1)) == -1)
        #expect(clip.speed(atSource: .zero) == -100)
    }
}
