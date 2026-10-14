import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

@Suite struct AnimatedValueTests {
    @Test func aStaticValueAppliesEverywhere() {
        let value = AnimatedValue(42.0)
        #expect(value.value(at: seconds(-1)) == 42)
        #expect(value.value(at: seconds(100)) == 42)
        #expect(!value.isAnimated)
    }

    @Test func keyframesBlendLinearlyAndHoldOutside() {
        var value = AnimatedValue(0.0)
        value.setAnimated(true, at: seconds(1))
        value.set(100, at: seconds(3))
        #expect(value.value(at: seconds(0)) == 0)
        #expect(value.value(at: seconds(2)) == 50)
        #expect(value.value(at: seconds(2.5)) == 75)
        #expect(value.value(at: seconds(5)) == 100)
    }

    @Test func settingAtAKeyframeReplacesIt() {
        var value = AnimatedValue(0.0)
        value.setAnimated(true, at: seconds(1))
        value.set(10, at: seconds(1))
        #expect(value.keyframes.count == 1)
        #expect(value.value(at: seconds(1)) == 10)
    }

    @Test func settingWhileStaticDoesNotAddKeyframes() {
        var value = AnimatedValue(0.0)
        value.set(10, at: seconds(1))
        #expect(!value.isAnimated)
        #expect(value.value == 10)
    }

    @Test func stoppingAnimationKeepsTheValueAtTheTime() {
        var value = AnimatedValue(0.0)
        value.setAnimated(true, at: seconds(0))
        value.set(100, at: seconds(2))
        value.setAnimated(false, at: seconds(1))
        #expect(!value.isAnimated)
        #expect(value.value == 50)
    }

    @Test func togglingAddsTheCurrentValueOrRemoves() {
        var value = AnimatedValue(0.0)
        value.toggleKeyframe(at: seconds(0))
        value.set(100, at: seconds(4))
        value.toggleKeyframe(at: seconds(1))
        #expect(value.keyframe(at: seconds(1))?.value == 25)
        value.toggleKeyframe(at: seconds(1))
        #expect(value.keyframe(at: seconds(1)) == nil)
        #expect(value.keyframes.count == 2)
    }

    @Test func removingTheLastKeyframeKeepsItsValue() {
        var value = AnimatedValue(0.0)
        value.setAnimated(true, at: seconds(1))
        value.set(30, at: seconds(1))
        value.removeKeyframe(at: seconds(1))
        #expect(!value.isAnimated)
        #expect(value.value == 30)
    }

    @Test func movingAKeyframeReplacesOneAtTheTarget() {
        var value = AnimatedValue(0.0)
        value.setAnimated(true, at: seconds(0))
        value.set(50, at: seconds(1))
        value.set(100, at: seconds(2))
        value.moveKeyframe(at: seconds(2), to: seconds(1))
        #expect(value.keyframes.map(\.time) == [seconds(0), seconds(1)])
        #expect(value.value(at: seconds(1)) == 100)
    }

    @Test func keyframesStaySortedWhenAddedOutOfOrder() {
        var value = AnimatedValue(0.0)
        value.setAnimated(true, at: seconds(3))
        value.set(10, at: seconds(1))
        value.set(20, at: seconds(2))
        #expect(value.keyframes.map(\.time) == [seconds(1), seconds(2), seconds(3)])
    }
}

@Suite struct LayerTransformTests {
    private let frame = CGSize(width: 1920, height: 1080)
    private var center: CGPoint { CGPoint(x: 960, y: 540) }

    @Test func identityLeavesContentAlone() {
        let transform = LayerTransform.identity.affineTransform(at: .zero, center: center)
        #expect(transform == .identity)
    }

    @Test func rotationTurnsClockwiseAboutTheFrameCenter() {
        var layer = LayerTransform()
        layer.rotation.set(90, at: .zero)
        let transform = layer.affineTransform(at: .zero, center: center)
        let mappedCenter = center.applying(transform)
        #expect(abs(mappedCenter.x - 960) < 0.001 && abs(mappedCenter.y - 540) < 0.001)
        // A point to the right of center ends up below it (y is down).
        let right = CGPoint(x: 1060, y: 540).applying(transform)
        #expect(abs(right.x - 960) < 0.001 && abs(right.y - 640) < 0.001)
    }

    @Test func scaleAndPositionAreAboutTheCenter() {
        var layer = LayerTransform()
        layer.setComponent(0, of: .scale, to: 50, at: .zero, frameSize: frame)
        layer.setComponent(0, of: .position, to: 1060, at: .zero, frameSize: frame)
        let transform = layer.affineTransform(at: .zero, center: center)
        let corner = CGPoint.zero.applying(transform)
        #expect(abs(corner.x - 580) < 0.001 && abs(corner.y - 270) < 0.001)
    }

    @Test func positionIsShownAbsoluteAndStoredFromTheCenter() {
        var layer = LayerTransform()
        #expect(layer.components(.position, at: .zero, frameSize: frame) == [960, 540])
        layer.setComponent(1, of: .position, to: 600, at: .zero, frameSize: frame)
        #expect(layer.position.value == Vector2(x: 0, y: 60))
    }

    @Test func linkedScaleKeepsItsAspect() {
        var layer = LayerTransform()
        layer.setComponent(0, of: .scale, to: 200, at: .zero, frameSize: frame)
        #expect(layer.scale.value == Vector2(x: 200, y: 200))
        layer.scaleLinked = false
        layer.setComponent(1, of: .scale, to: 50, at: .zero, frameSize: frame)
        #expect(layer.scale.value == Vector2(x: 200, y: 50))
    }

    @Test func opacityIsClamped() {
        var layer = LayerTransform()
        layer.setComponent(0, of: .opacity, to: 150, at: .zero, frameSize: frame)
        #expect(layer.opacity.value == 100)
        layer.setComponent(0, of: .opacity, to: -5, at: .zero, frameSize: frame)
        #expect(layer.opacity.value == 0)
    }

    @Test func keyframesSnapToFrames() {
        let timeline = Timeline(name: "T", layers: [], frameSize: frame, frameRate: 23.976, colorSpace: .rec709)
        let snapped = timeline.snappedToFrame(CMTime(seconds: 1.01, preferredTimescale: 600))
        #expect(snapped == CMTime(value: 24 * 1001, timescale: 24000))
        #expect(timeline.snappedToFrame(seconds(-1)) == .zero)
    }

    @Test func nestedStagesComposeAndMultiplyOpacity() {
        var inner = LayerTransform()
        inner.opacity.set(50, at: .zero)
        inner.position.set(Vector2(x: 10, y: 0), at: .zero)
        var outer = LayerTransform()
        outer.opacity.setAnimated(true, at: seconds(0))
        outer.opacity.set(0, at: seconds(2))
        let animation = PlacementAnimation(base: .identity, stages: [
            TransformStage(transform: inner, center: center, shift: seconds(1), toOuter: .identity),
            TransformStage(transform: outer, center: center, shift: .zero, toOuter: .identity),
        ])
        #expect(abs(animation.opacity(at: seconds(1)) - 0.25) < 0.0001)
        #expect(CGPoint.zero.applying(animation.transform(at: seconds(1))) == CGPoint(x: 10, y: 0))
        #expect(animation.animatedRanges == [CMTimeRange(start: .zero, end: seconds(2))])
    }
}

@Suite struct TransformCompositionTests {
    @Test func keyframedOpacityAndRotationAreSetPerFrame() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "amv-transform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appending(path: "m.mov")
        try await writeMovie(to: movie, segments: [(luma: 120, frames: 48)])

        var project = EditingProject.empty
        let media = MediaClip(
            name: "m", kind: .video, url: movie,
            duration: CMTime(seconds: 2, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        project.editTransform(of: ids.layerID, in: project.rootTimelineID) { transform in
            transform.opacity.setAnimated(true, at: .zero)
            transform.opacity.set(0, at: CMTime(value: 1, timescale: 1))
            transform.rotation.set(45, at: .zero)
        }

        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        let instruction = try #require(composed.videoComposition?.instructions.first as? AVVideoCompositionInstruction)
        let layer = try #require(instruction.layerInstructions.first)

        var startOpacity: Float = 0, endOpacity: Float = 0, range = CMTimeRange.zero
        // Half a second in (frame 12 of 24) the opacity is halfway down.
        _ = layer.getOpacityRamp(for: CMTime(value: 12, timescale: 24), startOpacity: &startOpacity, endOpacity: &endOpacity, timeRange: &range)
        #expect(abs(startOpacity - 0.5) < 0.001)
        // After the last keyframe it stays at zero.
        _ = layer.getOpacityRamp(for: CMTime(value: 36, timescale: 24), startOpacity: &startOpacity, endOpacity: &endOpacity, timeRange: &range)
        #expect(startOpacity == 0)

        var start = CGAffineTransform.identity, end = CGAffineTransform.identity
        _ = layer.getTransformRamp(for: CMTime(value: 12, timescale: 24), start: &start, end: &end, timeRange: &range)
        // 45° keeps a and d equal and positive, with b = -c.
        #expect(abs(start.a - start.d) < 0.0001 && start.a > 0 && abs(start.b + start.c) < 0.0001 && start.b > 0)
    }
}

@Suite struct KeyframeEaseTests {
    private func eased(_ preset: KeyframeEase.Preset) -> AnimatedValue<Double> {
        var value = AnimatedValue(0.0)
        value.setAnimated(true, at: seconds(0))
        value.set(100, at: seconds(4))
        value.applyEase(preset, at: seconds(0))
        value.applyEase(preset, at: seconds(4))
        return value
    }

    @Test func linearKeyframesStillBlendSteadily() {
        let value = eased(.linear)
        #expect(abs(value.value(at: seconds(1)) - 25) < 1e-6)
        #expect(abs(value.value(at: seconds(3)) - 75) < 1e-6)
    }

    @Test func easyEaseStartsAndEndsSlowlyAndPassesTheMiddle() {
        let value = eased(.easyEase)
        #expect(value.value(at: seconds(0.4)) < 5)
        #expect(abs(value.value(at: seconds(2)) - 50) < 1e-6)
        #expect(value.value(at: seconds(3.6)) > 95)
    }

    @Test func easeInAndOutChangeOnlyTheirSide() {
        var value = AnimatedValue(0.0)
        value.setAnimated(true, at: seconds(0))
        value.set(100, at: seconds(4))
        value.applyEase(.easeOut, at: seconds(0))
        #expect(value.keyframes[0].easeOut == .easy && value.keyframes[0].easeIn == nil)
        // Leaving slowly: behind a steady blend early on.
        #expect(value.value(at: seconds(1)) < 25)
        value.applyEase(.easeIn, at: seconds(0))
        #expect(value.keyframes[0].easeOut == .easy && value.keyframes[0].easeIn == .easy)
    }

    @Test func settingAndMovingKeepEases() {
        var value = eased(.easyEase)
        value.set(50, at: seconds(4))
        #expect(value.keyframes[1].easeIn == .easy)
        value.moveKeyframe(at: seconds(4), to: seconds(5))
        #expect(value.keyframes[1].time == seconds(5) && value.keyframes[1].easeIn == .easy)
    }

    @Test func handlesTurnIntoEasesAndBack() {
        let out = KeyframeEase(influence: 0.5, speed: 0.4)
        #expect(KeyframeEase.outgoing(handleAt: KeyframeEase.outgoingHandle(out)) == out)
        let into = KeyframeEase(influence: 0.25, speed: 2)
        let back = KeyframeEase.incoming(handleAt: KeyframeEase.incomingHandle(into))
        #expect(abs(back.influence - 0.25) < 1e-9 && abs(back.speed - 2) < 1e-9)
        // A handle dragged past the segment stays inside it.
        #expect(KeyframeEase.outgoing(handleAt: CGPoint(x: 1.5, y: 0)).influence == 1)
    }

    @Test func parametersReadAndWriteThroughComponents() {
        var layer = TimelineLayer(clips: [])
        layer.transform.position.setAnimated(true, at: seconds(0))
        layer.transform.position.set(Vector2(x: 10, y: 20), at: seconds(1))
        var position = layer[components: .transform(.position)]
        #expect(position.keyframes.map(\.value.values) == [[0, 0], [10, 20]])
        position.applyEase(.easyEase, at: seconds(1))
        layer[components: .transform(.position)] = position
        #expect(layer.transform.position.keyframes[1].easeIn == .easy)
        #expect(layer.transform.position.keyframes[1].value == Vector2(x: 10, y: 20))
    }
}

@Suite struct KeyframeGraphLayoutTests {
    @Test func theGraphFitsTheKeyframesAndMapsBothWays() {
        var value = AnimatedValue(0.0)
        value.setAnimated(true, at: seconds(1))
        value.set(50, at: seconds(3))
        let layout = KeyframeGraphLayout(value.asComponents, offset: [0], size: CGSize(width: 400, height: 200))
        // Every keyframe is inside the plot, with room around it.
        for keyframe in value.keyframes {
            #expect(layout.plot.insetBy(dx: 1, dy: 1).contains(CGPoint(x: layout.x(keyframe.time.seconds), y: layout.y(keyframe.value))))
        }
        #expect(abs(layout.seconds(atX: layout.x(2.25)) - 2.25) < 1e-9)
        #expect(abs(layout.value(atY: layout.y(12.5)) - 12.5) < 1e-9)
        // Higher values draw higher up.
        #expect(layout.y(50) < layout.y(0))
    }

    @Test func aFlatParameterStillGetsARange() {
        var value = AnimatedValue(Vector2(x: 5, y: 5))
        value.setAnimated(true, at: seconds(0))
        value.set(Vector2(x: 5, y: 5), at: seconds(2))
        let layout = KeyframeGraphLayout(value.asComponents, offset: [960, 540], size: CGSize(width: 400, height: 200))
        #expect(layout.values.contains(965) && layout.values.contains(545))
        #expect(layout.values.upperBound > layout.values.lowerBound)
    }
}
