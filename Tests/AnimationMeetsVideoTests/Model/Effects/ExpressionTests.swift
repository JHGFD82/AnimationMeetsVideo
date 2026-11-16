import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 24_000) }

/// The expression model with no Python (docs/python-scripting.md,
/// "Building it", step 4): results are put in `ExpressionResults` by hand,
/// as a run would put them.
@Suite struct ExpressionTests {
    /// The bridge's clip, with an Expression driving its Transform's
    /// Opacity, or its Position.
    private struct Fixture {
        var f = BridgeFixture()
        let expressionID: UUID

        init(driving kind: ControlKind = .opacity) {
            // As if typed here: only allowed code runs.
            for code in ["value", "value * 2", "a * sin(t * tau)"] { CodeApproval.allowInSession(code) }
            let target = KeyframingTarget.control(effectID: f.transformID, controlID: f.controlID(kind))
            expressionID = f.project.setKeyframing(.expression, driving: target, onClip: f.clipID, in: f.timelineID)!
        }

        var clip: TimelineClip { f.project.clipAndLayer(f.clipID, in: f.timelineID)!.clip }
        var timeline: Timeline { f.project.timeline(id: f.timelineID)! }
        var expression: Effect { clip.effect(id: expressionID)! }
        var opacity: AnimatedValue<ComponentValue> { clip.effect(id: f.transformID)!.control(.opacity)!.number }

        /// A result that fits the expression as it is now, with `value` at
        /// each frame of the clip.
        func result(reads: [KeyframingRead] = [], failure: ExpressionFailure? = nil, _ value: (Int) -> [Double]) -> ExpressionResult {
            let sampling = KeyframeSampling(clip: clip, range: CMTimeRange(start: clip.trimStart, end: clip.trimEnd), frame: timeline.frameDuration)
            let base = expression.keyframing?.base
            let values = sampling.sources.indices.flatMap(value)
            let width = value(0).count
            let print = f.project.expressionPrint(of: expression, in: clip, of: timeline, base: base, reads: reads)
            return ExpressionResult(times: sampling.sources, values: values, width: width, reads: reads, failure: failure, print: print)
        }

        mutating func land(_ result: ExpressionResult) {
            ExpressionResults.shared.store(result, for: expressionID)
            f.project.applyExpressionResults()
        }
    }

    @Test func aNewExpressionWaitsAndKeepsTheControlAsItWas() {
        let x = Fixture()
        #expect(x.expression.expression == "value")
        #expect(x.opacity.keyframes.isEmpty)
        #expect(x.f.project.waitingExpressions().map { $0.effectID } == [x.expressionID])
        #expect(x.f.project.keyframingNote(for: x.expression, in: x.clip)?.text == "Running\u{2026}")
    }

    @Test func codeFromElsewhereIsntRunUntilAllowed() {
        var x = Fixture()
        let code = "import os  # \(UUID())"
        x.f.project.editEffect(x.expressionID, ofClip: x.f.clipID, in: x.f.timelineID) { $0.expression = code }
        #expect(x.f.project.waitingExpressions().isEmpty)
        #expect(x.f.project.keyframingNote(for: x.expression, in: x.clip)?.text.hasPrefix("Expression not allowed yet") == true)
        CodeApproval.allowInSession(code)
        #expect(x.f.project.waitingExpressions().map { $0.effectID } == [x.expressionID])
    }

    @Test func aFittingResultIsWrittenAsGeneratedKeyframes() throws {
        var x = Fixture()
        // A ramp from 0 to 95 over the clip's 96 frames: a straight line,
        // thinned to its two ends.
        x.land(x.result { [Double($0)] })
        let keyframes = x.opacity.keyframes
        #expect(keyframes.count >= 2)
        #expect(keyframes.allSatisfy { $0.generatedBy == x.expressionID })
        #expect(keyframes.first?.value.values == [0])
        #expect(x.f.project.waitingExpressions().isEmpty)
        #expect(x.f.project.keyframingNote(for: x.expression, in: x.clip) == nil)
    }

    @Test func valuesAreClampedToTheControlsRange() {
        var x = Fixture()
        x.land(x.result { _ in [500] })
        #expect(x.opacity.keyframes.allSatisfy { $0.value.values == [100] })
    }

    @Test func steppedKeepsAHeldKeyframeAtEachSideOfAJump() {
        var x = Fixture()
        x.f.project.editEffect(x.expressionID, ofClip: x.f.clipID, in: x.f.timelineID) { effect in
            effect.changeControl(.expressionKeys) { $0.choice = ExpressionKeys.stepped.rawValue }
        }
        x.land(x.result { [$0 < 48 ? 20 : 80] })
        let values = x.opacity.keyframes.filter { $0.generatedBy == x.expressionID }.map { $0.value.values[0] }
        #expect(values.filter { $0 == 20 }.count == 2 && values.filter { $0 == 80 }.count == 2)
    }

    @Test func aStaleResultIsNotWritten() {
        var x = Fixture()
        let stale = x.result { _ in [10] }
        // The code changes after the run began.
        x.f.project.editEffect(x.expressionID, ofClip: x.f.clipID, in: x.f.timelineID) { $0.expression = "value * 2" }
        x.land(stale)
        #expect(x.opacity.keyframes.isEmpty)
        #expect(!x.f.project.waitingExpressions().isEmpty)
    }

    @Test func aSingleNumberSetsEveryComponentOfAVector() {
        var x = Fixture(driving: .position)
        x.land(x.result { _ in [7] })
        let position = x.clip.effect(id: x.f.transformID)!.control(.position)!.number
        #expect(position.keyframes.allSatisfy { $0.value.values == [7, 7] })
    }

    @Test func anErrorKeepsTheKeyframesAndSaysWhere() {
        var x = Fixture()
        x.land(x.result(failure: ExpressionFailure(summary: "Line 2: NameError: name 'tim' is not defined", time: nil)) { _ in [] })
        #expect(x.opacity.keyframes.isEmpty)
        #expect(x.f.project.keyframingNote(for: x.expression, in: x.clip)?.text == "Expression has an error. Line 2: NameError: name 'tim' is not defined")
        #expect(x.f.project.waitingExpressions().isEmpty)
    }

    @Test func eachReadPutsItOutOfDateAndNothingElseDoes() {
        var x = Fixture()
        let rotation = KeyframingRead(
            timeline: x.f.timelineID, kind: .control(clip: x.f.clipID, effect: x.f.transformID, control: x.f.controlID(.rotation))
        )
        x.land(x.result(reads: [rotation]) { _ in [50] })
        #expect(x.expression.keyframing?.reads == [rotation])
        #expect(x.f.project.waitingExpressions().isEmpty)
        // A control it didn't read: still current.
        let scaleID = x.f.controlID(.scale)
        x.f.project.editEffect(x.f.transformID, ofClip: x.f.clipID, in: x.f.timelineID) { effect in
            effect.controls[effect.controlIndex(scaleID)!].number = AnimatedValue(ComponentValue(values: [50, 50]))
        }
        #expect(x.f.project.waitingExpressions().isEmpty)
        // The one it read: out of date.
        let rotationID = x.f.controlID(.rotation)
        x.f.project.editEffect(x.f.transformID, ofClip: x.f.clipID, in: x.f.timelineID) { effect in
            effect.controls[effect.controlIndex(rotationID)!].number = AnimatedValue(ComponentValue(values: [45]))
        }
        #expect(x.f.project.waitingExpressions().map { $0.effectID } == [x.expressionID])
    }

    @Test func aTimelineReadElsewhereReachesItsReaders() {
        var x = Fixture()
        let titles = x.f.project.addTimeline(name: "Titles", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        x.land(x.result(reads: [KeyframingRead(timeline: titles, kind: .layerNames)]) { _ in [50] })
        #expect(x.f.project.expressionReaders(of: [titles]) == [x.f.timelineID])
        #expect(x.f.project.expressionReaders(of: [x.f.timelineID]).isEmpty)
        // Adding a layer there changes what a lookup by name finds.
        x.f.project.updateTimeline(titles) { $0.layers.append(TimelineLayer(customName: "Logo", clips: [])) }
        #expect(x.f.project.waitingExpressions().map { $0.effectID } == [x.expressionID])
    }

    @Test func readingItsOwnTargetIsNoLoop() {
        var x = Fixture()
        let own = KeyframingRead(timeline: x.f.timelineID, kind: .control(clip: x.f.clipID, effect: x.f.transformID, control: x.f.controlID(.opacity)))
        x.land(x.result(reads: [own]) { _ in [50] })
        #expect(x.f.project.expressionCycles().isEmpty)
    }

    @Test func aLoopOfTwoWritesNothingAndIsNamed() throws {
        var x = Fixture()
        let rotationTarget = KeyframingTarget.control(effectID: x.f.transformID, controlID: x.f.controlID(.rotation))
        let other = try #require(x.f.project.setKeyframing(.expression, driving: rotationTarget, onClip: x.f.clipID, in: x.f.timelineID))
        let readsRotation = KeyframingRead(timeline: x.f.timelineID, kind: .control(clip: x.f.clipID, effect: x.f.transformID, control: x.f.controlID(.rotation)))
        let readsOpacity = KeyframingRead(timeline: x.f.timelineID, kind: .control(clip: x.f.clipID, effect: x.f.transformID, control: x.f.controlID(.opacity)))
        // As their saved reads would have them.
        for (id, read) in [(x.expressionID, readsRotation), (other, readsOpacity)] {
            x.f.project.editClip(x.f.clipID, in: x.f.timelineID) { clip in
                if let index = clip.effects.index(of: id) { clip.effects[index].keyframing?.reads = [read] }
            }
        }
        let cycles = x.f.project.expressionCycles()
        #expect(Set(cycles.keys) == [x.expressionID, other])
        #expect(x.f.project.waitingExpressions().isEmpty)
        let note = try #require(x.f.project.keyframingNote(for: x.expression, in: x.clip)?.text)
        #expect(note.contains("Rotation") && note.contains("reads it back"))
    }

    @Test func aLoopOfThreeAcrossTimelinesIsFound() {
        var project = EditingProject.empty
        /// An adjustment clip with a Transform and an Expression driving
        /// its Position.
        func clip() -> TimelineClip {
            let transform = Effect(kind: .transform)
            var expression = Effect(kind: .expression)
            expression.keyframing?.target = .control(effectID: transform.id, controlID: transform.controls[0].id)
            var clip = TimelineClip(source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: seconds(1))
            clip.effects = [expression, transform]
            return clip
        }
        // Three expressions, each reading the next one's target, across two
        // timelines.
        let main = project.rootTimelineID
        let titles = project.addTimeline(name: "Titles", frameSize: CGSize(width: 10, height: 10), frameRate: 24, colorSpace: .rec709)
        var clips = [(main, clip()), (titles, clip()), (main, clip())]
        func target(_ i: Int) -> KeyframingRead {
            let (timeline, clip) = clips[i]
            return KeyframingRead(timeline: timeline, kind: .control(clip: clip.id, effect: clip.effects[1].id, control: clip.effects[1].controls[0].id))
        }
        for i in 0..<3 { clips[i].1.effects[0].keyframing?.reads = [target((i + 1) % 3)] }
        for (timeline, clip) in clips {
            project.updateTimeline(timeline) { $0.layers.append(TimelineLayer(clips: [clip], isAdjustment: true)) }
        }
        #expect(Set(project.expressionCycles().keys) == Set(clips.map { $0.1.effects[0].id }))
    }

    @Test func bakeKeepsTheKeyframesAndDropsTheCode() {
        var x = Fixture()
        x.land(x.result { [Double($0)] })
        let made = x.opacity
        x.f.project.bakeKeyframing(x.expressionID, ofClip: x.f.clipID, in: x.f.timelineID)
        #expect(x.clip.effect(id: x.expressionID) == nil)
        #expect(x.opacity.keyframes.map(\.time) == made.keyframes.map(\.time))
        #expect(x.opacity.keyframes.allSatisfy { $0.generatedBy == nil })
    }

    @Test func anExpressionSavesAndLoadsItsCodeAndReads() async throws {
        var x = Fixture()
        x.f.project.editEffect(x.expressionID, ofClip: x.f.clipID, in: x.f.timelineID) { $0.expression = "a * sin(t * tau)" }
        let read = KeyframingRead(timeline: x.f.timelineID, kind: .layerNames)
        x.land(x.result(reads: [read]) { _ in [30] })
        let package = FileManager.default.temporaryDirectory.appending(path: "amv-expression-\(UUID().uuidString).amv", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: package) }
        try await ProjectStore.save(x.f.project, to: package)
        let media = x.f.project.clips[0]
        let loaded = try await ProjectStore.load(from: package, importMedia: { _ in media }).project
        let effect = try #require(loaded.clipAndLayer(x.f.clipID, in: x.f.timelineID)?.clip.effect(id: x.expressionID))
        #expect(effect.expression == "a * sin(t * tau)")
        #expect(effect.keyframing?.reads == [read])
        #expect(effect.keyframing?.readPrint == x.expression.keyframing?.readPrint)
        // Opening a project never starts Python when nothing it read changed.
        ExpressionResults.shared.removeAll()
        #expect(loaded.waitingExpressions().isEmpty)
    }

    @Test func expressionOnAnotherKindIsRefusedWithItsPath() throws {
        let shape = ProjectFile.ShapeKit.effect(.transform, extra: [])
        let json = Data(#"{"id": "\#(UUID().uuidString)", "kind": "transform", "expression": "1", "controls": []}"#.utf8)
        #expect(throws: (any Error).self) { try StrictJSON.validate(json, against: .object(shape)) }
    }
}
