import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Expressions called between frames, at the moments motion blur draws
/// (docs/python-scripting.md, "Between frames").
@Suite struct BetweenFramesTests {
    private let frame = 1.0 / 24

    private func blurred(angle: Double, samples: Int) -> ClipShutter {
        var shutter = ClipShutter()
        shutter.motionBlur = MotionBlur(angle: angle, samples: samples)
        return shutter
    }

    @Test func autoTakesTheCompositorsMomentsForTheClipsShutter() {
        let offsets = BetweenFrames.auto.offsets(shutter: blurred(angle: 180, samples: 4), frame: frame)
        // The compositor's own: shutter × ((i + 0.5) / n − 0.5).
        let shutter = frame * 180 / 360
        let expected = (0..<4).map { shutter * ((Double($0) + 0.5) / 4 - 0.5) }
        #expect(offsets == expected)
        // Within the open shutter, around the frame's own time.
        #expect(offsets.allSatisfy { abs($0) < shutter / 2 })
    }

    @Test func autoTakesAtMostEightAndNoneWithoutBlur() {
        #expect(BetweenFrames.auto.offsets(shutter: blurred(angle: 360, samples: 64), frame: frame).count == 8)
        #expect(BetweenFrames.auto.offsets(shutter: ClipShutter(), frame: frame).isEmpty)
        #expect(BetweenFrames.off.offsets(shutter: blurred(angle: 180, samples: 8), frame: frame).isEmpty)
    }

    @Test func twoFourAndEightSpreadOverTheWholeFrameWhateverTheShutter() {
        let four = BetweenFrames.four.offsets(shutter: ClipShutter(), frame: frame)
        #expect(four.count == 4)
        #expect(four.first! == frame * (0.5 / 4 - 0.5) && four.last! == frame * (3.5 / 4 - 0.5))
        #expect(BetweenFrames.eight.offsets(shutter: blurred(angle: 90, samples: 2), frame: frame).count == 8)
    }

    @Test func samplingAddsTheMomentsInOrderInsideTheRange() {
        let clip = TimelineClip(source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 1, timescale: 4))
        let range = CMTimeRange(start: clip.trimStart, end: clip.trimEnd)
        let frames = KeyframeSampling(clip: clip, range: range, frame: CMTime(value: 1, timescale: 24))
        let between = KeyframeSampling(
            clip: clip, range: range, frame: CMTime(value: 1, timescale: 24),
            between: BetweenFrames.two.offsets(shutter: ClipShutter(), frame: frame)
        )
        #expect(frames.timelineTimes.count == 7)
        #expect(between.timelineTimes == between.timelineTimes.sorted())
        // Each frame keeps its sample; the moments before the first frame
        // and after the last are outside the range.
        #expect(Set(frames.timelineTimes).isSubset(of: Set(between.timelineTimes)))
        #expect(between.timelineTimes.count == 7 + 6 * 2)
        #expect(between.sources.count == between.timelineTimes.count && between.elapsed.count == between.timelineTimes.count)
    }

    /// The bridge's clip with an Expression on Opacity, its result made
    /// from `value` at each of its moments, with Between Frames 4.
    private func written(_ value: (Double) -> Double) -> AnimatedValue<ComponentValue> {
        var f = BridgeFixture()
        CodeApproval.allowInSession("value")
        let target = KeyframingTarget.control(effectID: f.transformID, controlID: f.controlID(.opacity))
        let id = f.project.setKeyframing(.expression, driving: target, onClip: f.clipID, in: f.timelineID)!
        f.project.editEffect(id, ofClip: f.clipID, in: f.timelineID) { effect in
            effect.changeControl(.betweenFrames) { $0.choice = BetweenFrames.four.rawValue }
            effect.changeControl(.tolerance) { $0.number = AnimatedValue(ComponentValue(values: [0.01])) }
        }
        let clip = f.project.clipAndLayer(f.clipID, in: f.timelineID)!.clip
        let timeline = f.project.timeline(id: f.timelineID)!
        let effect = clip.effect(id: id)!
        let sampling = KeyframeSampling(
            clip: clip, range: CMTimeRange(start: clip.trimStart, end: clip.trimEnd), frame: timeline.frameDuration,
            between: BetweenFrames.four.offsets(shutter: clip.shutter, frame: timeline.frameDuration.seconds)
        )
        let base = effect.keyframing?.base ?? EditingProject.removingKeyframes(of: id, from: clip.number(of: target)!)
        let result = ExpressionResult(
            times: sampling.sources, values: sampling.elapsed.map(value), width: 1, reads: [], failure: nil,
            print: f.project.expressionPrint(of: effect, in: clip, of: timeline, base: base, reads: [])
        )
        ExpressionResults.shared.store(result, for: id)
        f.project.applyExpressionResults()
        return f.project.clipAndLayer(f.clipID, in: f.timelineID)!.clip.effect(id: f.transformID)!.control(.opacity)!.number
    }

    @Test func aMoveStraightWithinTheFrameKeepsNoExtraKeyframes() {
        let keyframes = written { 10 + $0 * 20 }.keyframes
        // A straight line keeps its two ends, whatever the moments.
        #expect(keyframes.count == 2)
    }

    @Test func aCurvedMoveKeepsMomentsBetweenFrames() {
        let keyframes = written { 50 + 40 * sin($0 * .pi * 2 * 6) }.keyframes
        let frame = 1.0 / 24
        let between = keyframes.filter { keyframe in
            let frames = keyframe.time.seconds / frame
            return abs(frames - frames.rounded()) > 1e-6
        }
        #expect(!between.isEmpty)
    }

    @Test func aChangedShutterPutsAnAutoExpressionOutOfDate() {
        let f = BridgeFixture()
        var clip = f.project.clipAndLayer(f.clipID, in: f.timelineID)!.clip
        let timeline = f.project.timeline(id: f.timelineID)!
        let expression = Effect(kind: .expression)
        let before = f.project.expressionPrint(of: expression, in: clip, of: timeline, base: nil, reads: [])
        clip.shutter = blurred(angle: 180, samples: 8)
        #expect(f.project.expressionPrint(of: expression, in: clip, of: timeline, base: nil, reads: []) != before)
    }
}
