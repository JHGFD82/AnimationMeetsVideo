import CoreMedia
import Testing
@testable import AnimationMeetsVideo

/// Where a clip block's volume line is read (`VolumeLineView.points`).
struct VolumeLineTests {
    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    @Test func aSteadyLevelIsALineBetweenTheEnds() {
        let points = VolumeLineView.points(of: AnimatedValue(-6), firstSeconds: 0, pixelsPerSecond: 100, width: 400)
        #expect(points.map(\.x) == [0, 400])
        #expect(points.allSatisfy { $0.level == -6 })
    }

    /// Keyframes out of the drawn stretch hold the level across it.
    @Test func keyframesOutOfViewLeaveTheLevelSteady() {
        let volume = AnimatedValue(0.0, keyframes: [
            Keyframe(time: seconds(0), value: -12), Keyframe(time: seconds(1), value: 0),
        ])
        let points = VolumeLineView.points(of: volume, firstSeconds: 2, pixelsPerSecond: 100, width: 300)
        #expect(points.count == 2)
        #expect(points.allSatisfy { $0.level == 0 })
    }

    @Test func aRampIsReadAtItsKeyframesAndInSteps() {
        let volume = AnimatedValue(0.0, keyframes: [
            Keyframe(time: seconds(0.5), value: -12), Keyframe(time: seconds(1.03), value: 0),
        ])
        let points = VolumeLineView.points(of: volume, firstSeconds: 0, pixelsPerSecond: 100, width: 200)
        let xs = points.map(\.x)
        #expect(xs == xs.sorted())
        #expect(xs.first == 0)
        #expect(xs.last == 200)
        #expect(xs.contains { abs($0 - 50) < 0.001 })
        #expect(xs.contains { abs($0 - 103) < 0.001 })
        // Far fewer than one every two points.
        #expect(points.count < 50)
        #expect(points.first?.level == -12)
        #expect(points.last?.level == 0)
    }

    /// A hold keyframe steps straight up at the next keyframe.
    @Test func aHoldStepsAtTheNextKeyframe() {
        var held = Keyframe(time: seconds(0.2), value: -20.0)
        held.hold = true
        let volume = AnimatedValue(0.0, keyframes: [held, Keyframe(time: seconds(1), value: 0)])
        let points = VolumeLineView.points(of: volume, firstSeconds: 0, pixelsPerSecond: 100, width: 200)
        let before = try? #require(points.last { $0.x < 100 })
        let at = try? #require(points.first { $0.x >= 100 })
        #expect(before?.level == -20)
        #expect(at?.level == 0)
        #expect((at?.x ?? 0) - (before?.x ?? 0) < 0.1)
    }
}
