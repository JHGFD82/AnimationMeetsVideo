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

@Suite struct TransformStackTests {
    private let center = CGPoint(x: 960, y: 540)

    /// A stack of one Transform effect holding just these controls.
    private func transform(_ controls: [(ControlKind, [Double])], movesAnchor: Bool = true) -> Effect {
        var effect = Effect(kind: .transform, controls: [])
        effect.movesAnchor = movesAnchor
        for (kind, values) in controls {
            var control = EffectControl(kind: kind)
            control.number = AnimatedValue(ComponentValue(values: values))
            effect.controls.append(control)
        }
        return effect
    }

    private func fold(_ effects: [Effect], anchor: Vector2 = .zero, at time: CMTime = .zero) -> FoldedPlacement {
        StackFolding.fold(effects: effects, anchorPoint: AnimatedValue(anchor), at: time, center: center)
    }

    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001
    }

    @Test func anEmptyStackLeavesThePictureAlone() {
        let placement = fold([])
        #expect(placement.matrix == .identity && placement.opacity == 1)
        #expect(fold([Effect(kind: .transform)]).matrix == .identity)
    }

    @Test func rotationTurnsClockwiseAboutTheCenter() {
        let placement = fold([transform([(.rotation, [90])])])
        #expect(close(center.applying(placement.matrix), center))
        // A point to the right of center ends up below it (y is down).
        #expect(close(CGPoint(x: 1060, y: 540).applying(placement.matrix), CGPoint(x: 960, y: 640)))
    }

    @Test func scaleAndPositionWorkOnTheScreen() {
        let placement = fold([transform([(.scale, [50, 50]), (.position, [100, 0])])])
        #expect(close(CGPoint.zero.applying(placement.matrix), CGPoint(x: 580, y: 270)))
    }

    @Test func positionAfterAScaleMovesByThePixelsAsked() {
        let placement = fold([transform([(.scale, [200, 200]), (.position, [5, 0])])])
        #expect(close(center.applying(placement.matrix), CGPoint(x: 965, y: 540)))
    }

    /// With a uniform Scale. A stretch (x and y apart) works along the
    /// screen's axes, so it doesn't commute with a turn.
    @Test func stepsGiveTheSamePictureInAnyOrderWithinAnEffect() {
        let steps: [(ControlKind, [Double])] = [(.position, [40, -25]), (.scale, [150, 150]), (.rotation, [30])]
        let a = fold([transform(steps)]).matrix
        let b = fold([transform(steps.reversed())]).matrix
        let c = fold([transform([steps[1], steps[2], steps[0]])]).matrix
        for point in [CGPoint.zero, CGPoint(x: 300, y: 120), center] {
            #expect(close(point.applying(a), point.applying(b)))
            #expect(close(point.applying(a), point.applying(c)))
        }
    }

    @Test func repeatsCompound() {
        let step = transform([(.position, [5, 0])])
        let moved = fold(Array(repeating: step, count: 50)).matrix
        #expect(close(center.applying(moved), CGPoint(x: 1210, y: 540)))
        let grown = fold(Array(repeating: transform([(.scale, [102, 102])]), count: 50)).matrix
        #expect(abs(grown.a - pow(1.02, 50)) < 0.0001)
        let faded = fold(Array(repeating: transform([(.opacity, [50])]), count: 2))
        #expect(abs(faded.opacity - 0.25) < 1e-9)
    }

    @Test func theAnchorPointIsWhatScaleAndRotationTurnAbout() {
        let placement = fold([transform([(.rotation, [180])])], anchor: Vector2(x: 100, y: 0))
        // The anchor stays put; the center swings round it to the other side.
        #expect(close(CGPoint(x: 1060, y: 540).applying(placement.matrix), CGPoint(x: 1060, y: 540)))
        #expect(close(center.applying(placement.matrix), CGPoint(x: 1160, y: 540)))
    }

    @Test func positionCarriesTheAnchorUnlessTold() {
        let steps: [(ControlKind, [Double])] = [(.position, [200, 0]), (.rotation, [180])]
        let carried = fold([transform(steps)])
        // Turned about its own, moved, center: stays where it was moved to.
        #expect(close(center.applying(carried.matrix), CGPoint(x: 1160, y: 540)))
        let pinned = fold([transform(steps, movesAnchor: false)])
        // Turned about the frame center, so the moved picture orbits it.
        #expect(close(center.applying(pinned.matrix), CGPoint(x: 760, y: 540)))
    }

    @Test func opacityIsClamped() {
        #expect(fold([transform([(.opacity, [150])])]).opacity == 1)
        #expect(fold([transform([(.opacity, [-5])])]).opacity == 0)
    }

    @Test func disabledEffectsAndControlsAreSkipped() {
        var effect = transform([(.position, [50, 0])])
        effect.enabled = false
        #expect(fold([effect]).matrix == .identity)
        effect.enabled = true
        effect.controls[0].enabled = false
        #expect(fold([effect]).matrix == .identity)
    }

    @Test func keyframesAreReadInSourceTime() {
        var effect = Effect(kind: .transform, controls: [EffectControl(kind: .rotation)])
        effect.controls[0].number.setAnimated(true, at: seconds(10))
        effect.controls[0].number.set(ComponentValue(values: [90]), at: seconds(12))
        let halfway = fold([effect], at: seconds(11))
        #expect(abs(halfway.matrix.b - sin(Double.pi / 4)) < 1e-6)
    }

    @Test func linkedScaleKeepsItsProportionAndUnlinkedDoesNot() {
        var control = EffectControl(kind: .scale)
        control.setComponent(0, to: 200, at: .zero)
        #expect(control.number.value.values == [200, 200])
        control.linked = false
        control.setComponent(1, to: 50, at: .zero)
        #expect(control.number.value.values == [200, 50])
    }

    @Test func opacityAndAmountControlsAreClamped() {
        var control = EffectControl(kind: .opacity)
        control.setComponent(0, to: 150, at: .zero)
        #expect(control.number.value.values == [100])
        control.setComponent(0, to: -5, at: .zero)
        #expect(control.number.value.values == [0])
    }

    @Test func controlsAtTheirDefaultsAreNoOps() {
        var effect = Effect(kind: .transform)
        #expect(effect.isNoOp)
        effect.controls[2].setComponent(0, to: 10, at: .zero)
        #expect(!effect.isNoOp && !effect.controls[2].isNoOp && effect.controls[0].isNoOp)
        effect.controls[2].reset()
        #expect(effect.isNoOp)
    }

    @Test func newEffectsAreNumberedByKind() {
        var stack: [Effect] = []
        for _ in 0..<3 { stack.append(Effect.make(.transform, among: stack)) }
        stack.append(Effect.make(.blending, among: stack))
        #expect(stack.map(\.displayName) == ["Transform", "Transform 2", "Transform 3", "Blending"])
    }

    @Test func duplicatesGetNewIDs() {
        let effect = Effect(kind: .transform)
        let copy = effect.duplicated()
        #expect(copy.id != effect.id && copy.controls.map(\.id) != effect.controls.map(\.id))
        #expect(copy.controls.map(\.kind) == effect.controls.map(\.kind))
    }

    @Test func blendingNeedsAModeAndAnAmount() {
        var effect = Effect(kind: .blending)
        #expect(effect.isNoOp)
        effect.controls[0].blendMode = .multiply
        #expect(!effect.isNoOp)
        effect.controls[1].setComponent(0, to: 0, at: .zero)
        #expect(effect.isNoOp)
    }

    @Test func keyframesSnapToFrames() {
        let timeline = Timeline(name: "T", layers: [], frameSize: CGSize(width: 1920, height: 1080), frameRate: 23.976, colorSpace: .rec709)
        let snapped = timeline.snappedToFrame(CMTime(seconds: 1.01, preferredTimescale: 600))
        #expect(snapped == CMTime(value: 24 * 1001, timescale: 24000))
        #expect(timeline.snappedToFrame(seconds(-1)) == .zero)
    }

    @Test func nestedStagesComposeAndMultiplyOpacity() {
        var inner = Effect(kind: .transform)
        inner.controls[0].number = AnimatedValue(ComponentValue(values: [10, 0]))
        inner.controls[3].number = AnimatedValue(ComponentValue(values: [50]))
        var outer = Effect(kind: .transform, controls: [EffectControl(kind: .opacity)])
        outer.controls[0].number.setAnimated(true, at: seconds(0))
        outer.controls[0].number.set(ComponentValue(values: [0]), at: seconds(2))
        let animation = PlacementAnimation(base: .identity, stages: [
            TransformStage(effects: [inner], anchorPoint: AnimatedValue(.zero), center: center, shift: seconds(1), sourceShift: .zero, toOuter: .identity),
            TransformStage(effects: [outer], anchorPoint: AnimatedValue(.zero), center: center, shift: .zero, sourceShift: .zero, toOuter: .identity),
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
        var effect = Effect(kind: .transform)
        effect.controls[3].number.setAnimated(true, at: .zero)
        effect.controls[3].number.set(ComponentValue(values: [0]), at: CMTime(value: 1, timescale: 1))
        effect.controls[2].number = AnimatedValue(ComponentValue(values: [45]))
        project.editClip(ids.clipID, in: project.rootTimelineID) { $0.effects = [effect] }

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

    @Test func parametersReadAndWriteThroughComponents() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let media = MediaClip(name: "m", kind: .video, url: nil, duration: seconds(5), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let imported = project.importClip(media, intoTimeline: timelineID)
        let ids = try #require(imported)
        let effect = Effect(kind: .transform)
        project.editClip(ids.clipID, in: timelineID) { $0.effects = [effect] }
        let position = try #require(effect.control(.position))
        let key = ParameterKey(
            timelineID: timelineID,
            parameter: .control(.position, clipID: ids.clipID, effectID: effect.id, controlID: position.id)
        )
        project.editComponents(of: key) {
            $0.setAnimated(true, at: seconds(0))
            $0.set(ComponentValue(values: [10, 20]), at: seconds(1))
            $0.applyEase(.easyEase, at: seconds(1))
        }
        let components = try #require(project.components(of: key))
        #expect(components.keyframes.map(\.value.values) == [[0, 0], [10, 20]])
        #expect(components.keyframes[1].easeIn == .easy)
        let stored = try #require(project.clipAndLayer(ids.clipID, in: timelineID)?.clip.effects.first?.controls.first)
        #expect(stored.number.keyframes[1].value.values == [10, 20])
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
