import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

/// 0 at 0 s, 10 at 2 s, 30 at 4 s, with the first keyframe set to hold.
private func held() -> AnimatedValue<Double> {
    var value = AnimatedValue(0.0)
    value.setAnimated(true, at: .zero)
    value.set(10, at: seconds(2))
    value.set(30, at: seconds(4))
    value.applyEase(.hold, at: .zero)
    return value
}

@Suite struct HoldKeyframeTests {
    @Test func aHoldKeepsItsValueUntilTheNextKeyframe() {
        let value = held()
        #expect(value.value(at: seconds(1)) == 0)
        #expect(value.value(at: CMTime(value: 1199, timescale: 600)) == 0)
        #expect(value.value(at: seconds(2)) == 10)
        // After a keyframe that doesn't hold, the value blends as before.
        #expect(value.value(at: seconds(3)) == 20)
        #expect(value.value(atSeconds: 1.999999) == 0)
        #expect(value.value(atSeconds: 2) == 10)
        #expect(value.value(atSeconds: 3) == 20)
    }

    @Test func presetsThatSetTheWayOutEndAHold() {
        var value = held()
        value.applyEase(.easeIn, at: .zero)
        #expect(value.keyframes[0].hold)
        #expect(value.keyframes[0].easeIn == .easy)
        value.applyEase(.easeOut, at: .zero)
        #expect(!value.keyframes[0].hold)
        #expect(value.value(at: seconds(1)) != 0)
        value.applyEase(.hold, at: .zero)
        #expect(value.keyframes[0].hold && value.keyframes[0].easeOut == nil)
        value.applyEase(.linear, at: .zero)
        #expect(!value.keyframes[0].hold)
    }

    @Test func togglingHoldSwitchesItAndLeavesTheWayOutLinear() {
        var value = held()
        value.toggleHold(at: .zero)
        #expect(!value.keyframes[0].hold && value.keyframes[0].easeOut == nil)
        #expect(value.value(at: seconds(1)) == 5)
        value.toggleHold(at: .zero)
        #expect(value.keyframes[0].hold)
    }

    @Test func aHoldMovesAndConvertsWithItsKeyframe() {
        var value = held()
        value.moveKeyframe(at: .zero, to: seconds(1))
        #expect(value.keyframes[0].hold)
        #expect(value.shifted(by: seconds(1)).keyframes[0].hold)
        let components = value.asComponents
        #expect(components.keyframes[0].hold)
        #expect(AnimatedValue<Double>(components: components) == value)
    }

    @Test func aHeldSpeedIsAStep() {
        // 50% for the first 2 s of source, then 200%.
        var clip = TimelineClip(source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: seconds(4))
        clip.time.speed.setAnimated(true, at: .zero)
        clip.time.speed.set(50, at: .zero)
        clip.time.speed.set(200, at: seconds(2))
        clip.time.speed.applyEase(.hold, at: .zero)
        // 2 s of source at 50% take 4 s, and 2 s more at 200% take 1 s, to
        // within a tick of the 1/240000 s a ramped time is given in (which
        // is cut toward zero, so a hair under is a whole tick under).
        let placed = 1.5 / 240_000
        #expect(abs(clip.timelineTime(forSourceTime: seconds(2)).seconds - 4) < placed)
        #expect(abs(clip.placedDuration.seconds - 5) < placed)
        #expect(abs(clip.sourceTime(atTimelineTime: seconds(4.5)).seconds - 3) < placed)
        #expect(clip.speed(atSource: seconds(1.99)) == 50)
        #expect(clip.speed(atSource: seconds(2)) == 200)
    }

    @Test func reversingAndClampingKeepTheHold() {
        var time = ClipTime()
        time.speed.setAnimated(true, at: .zero)
        time.speed.set(50, at: .zero)
        time.speed.set(200, at: seconds(2))
        time.speed.applyEase(.hold, at: .zero)
        time.setReversed(true)
        #expect(time.speed.keyframes.map(\.hold) == [true, false])
        #expect(time.speed.keyframes.map(\.value) == [-50, -200])
    }
}
