import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A run of an expression, end to end with a stand-in for Python: what is
/// sent, and the result that comes back fitting and being written.
@MainActor @Suite struct ExpressionRunnerTests {
    private func fixture() -> (BridgeFixture, UUID) {
        var f = BridgeFixture()
        CodeApproval.allowInSession("value")
        let target = KeyframingTarget.control(effectID: f.transformID, controlID: f.controlID(.opacity))
        let id = f.project.setKeyframing(.expression, driving: target, onClip: f.clipID, in: f.timelineID)!
        return (f, id)
    }

    @Test func theRequestCarriesATableForEachNameOneSamplePerFrame() throws {
        let (f, id) = fixture()
        let prepared = try #require(ExpressionRunner.request(for: .init(timelineID: f.timelineID, clipID: f.clipID, effectID: id), in: f.project))
        let count = prepared.times.count
        // Four seconds at 24 fps, both ends included.
        #expect(count == 97 && prepared.width == 1)
        let header = prepared.request.header(id: 1)
        #expect(header["type"] == "expression" && header["count"] == .number(Double(count)))
        // time, t, frame, source_time, value and a to d: nine numbers a sample.
        #expect(prepared.request.payload.count == count * 9 * 8)
        #expect(header["context"]?["clip"] == JSONValue(f.clipID))
        #expect(prepared.request.timeLimit == ExpressionRunner.timeLimit)
    }

    @Test func samplesComeBackAsAResultThatFitsAndIsWritten() async throws {
        var (f, id) = fixture()
        let job = ExpressionRunner.Job(timelineID: f.timelineID, clipID: f.clipID, effectID: id)
        let count = try #require(ExpressionRunner.request(for: job, in: f.project)).times.count
        let runner = ExpressionRunner(helper: FakeHelper(end: .samples((0..<count).map { Double($0) })))
        let result = try #require(await runner.run(job, in: f.project))
        #expect(result.failure == nil && result.values.count == count)
        ExpressionResults.shared.store(result, for: id)
        // Outside #expect, whose expansion can't run a mutating call.
        let applied = f.project.applyExpressionResults()
        #expect(applied)
        let opacity = f.project.clipAndLayer(f.clipID, in: f.timelineID)!.clip.effect(id: f.transformID)!.control(.opacity)!.number
        #expect(opacity.keyframes.allSatisfy { $0.generatedBy == id } && !opacity.keyframes.isEmpty)
        #expect(f.project.waitingExpressions().isEmpty)
    }

    @Test func anErrorComesBackAsAFailureWithItsMoment() async throws {
        let (f, id) = fixture()
        let job = ExpressionRunner.Job(timelineID: f.timelineID, clipID: f.clipID, effectID: id)
        let error = ScriptFailure(exception: "NameError", message: "name 'tim' is not defined", line: 2, time: 1.5)
        let result = try #require(await ExpressionRunner(helper: FakeHelper(end: .failed(error))).run(job, in: f.project))
        #expect(result.failure == ExpressionFailure(summary: "Line 2: NameError: name 'tim' is not defined", time: 1.5))
    }

    @Test func tooFewSamplesAreAFailure() async throws {
        let (f, id) = fixture()
        let job = ExpressionRunner.Job(timelineID: f.timelineID, clipID: f.clipID, effectID: id)
        let result = try #require(await ExpressionRunner(helper: FakeHelper(end: .samples([1, 2]))).run(job, in: f.project))
        #expect(result.failure != nil)
    }

    @Test func anExpressionCantChangeTheProject() async throws {
        let (f, _) = fixture()
        let bridge = ProjectBridge(project: f.project, readsOnly: true)
        var arguments = f.clipArguments
        arguments["time"] = [2, 1]
        #expect(await bridge.error("set_start", arguments)?.kind == .readOnly)
        _ = try await bridge.value("clip", f.clipArguments)
        #expect(await bridge.reads == [KeyframingRead(timeline: f.timelineID, kind: .clip(f.clipID))])
    }

    @Test func readingItsOwnTargetGivesTheBaseAndIsntARead() async throws {
        let (f, id) = fixture()
        let own = KeyframingRead(timeline: f.timelineID, kind: .control(clip: f.clipID, effect: f.transformID, control: f.controlID(.opacity)))
        let base = AnimatedValue(ComponentValue(values: [42]))
        let bridge = ProjectBridge(project: f.project, context: ProjectBridge.Context(ownTarget: own, ownBase: base), readsOnly: true)
        _ = id
        let frames = try await bridge.value("control_frames", ["target": f.target(.opacity)])
        #expect(frames["values"]?.array?.allSatisfy { $0 == 42 } == true)
        #expect(await bridge.reads.isEmpty)
    }

    /// A read-only bridge for the fixture's expression, with its samples.
    private func expressionBridge(
        _ f: BridgeFixture, audio: AudioKeysSource? = nil, beats: UUID? = nil
    ) -> ProjectBridge {
        let own = KeyframingRead(timeline: f.timelineID, kind: .control(clip: f.clipID, effect: f.transformID, control: f.controlID(.opacity)))
        let times = (0..<5).map { CMTime(value: Int64($0), timescale: 24) }
        return ProjectBridge(
            project: f.project,
            context: ProjectBridge.Context(ownTarget: own, sampleTimes: times, audioSource: audio, beatLayer: beats),
            readsOnly: true
        )
    }

    @Test func wiggleAndNoiseAreWigglersOwn() async throws {
        let (f, _) = fixture()
        let bridge = expressionBridge(f)
        let stream = KeyframeGenerators.hash(UInt64(7) &* 31 &+ 1)
        let wiggle = try await bridge.value("wiggle", ["frequency": 2, "seed": 7, "dimension": 1])
        let expected = (0..<5).map { JSONValue.number(KeyframeGenerators.fractalNoise(Double($0) / 24 * 2, octaves: 1, stream: stream, smooth: true)) }
        #expect(wiggle == .array(expected))
        let noise = try await bridge.value("noise", ["xs": [0.25], "seed": 7, "dimension": 1])
        #expect(noise == [.number(KeyframeGenerators.noise(0.25, stream: stream, smooth: true))])
        // Neither reads the project.
        #expect(await bridge.reads.isEmpty)
    }

    @Test func audioAndBeatsNeedTheirSourceChosen() async {
        let (f, _) = fixture()
        let bridge = expressionBridge(f)
        #expect(await bridge.error("audio_levels", ["low": 20, "high": 200])?.message.contains("Listen To") == true)
        #expect(await bridge.error("beat_times")?.message.contains("Beats From") == true)
    }

    @Test func beatsAreTheLayersAndAreARead() async throws {
        var (f, _) = fixture()
        let music = TimelineLayer(kind: .music, clips: [])
        f.project.updateTimeline(f.timelineID) { $0.layers.append(music) }
        let bridge = expressionBridge(f, beats: music.id)
        #expect(try await bridge.value("beat_times") == [])
        #expect(await bridge.reads == [KeyframingRead(timeline: f.timelineID, kind: .beats(layer: music.id))])
    }

    @Test func choosingListenToOrBeatsFromPutsItOutOfDate() throws {
        var (f, id) = fixture()
        let clip = f.project.clipAndLayer(f.clipID, in: f.timelineID)!.clip
        let timeline = f.project.timeline(id: f.timelineID)!
        let before = f.project.expressionPrint(of: clip.effect(id: id)!, in: clip, of: timeline, base: nil, reads: [])
        f.project.editEffect(id, ofClip: f.clipID, in: f.timelineID) { $0.keyframing?.audioSource = .mix }
        let after = f.project.clipAndLayer(f.clipID, in: f.timelineID)!.clip
        #expect(f.project.expressionPrint(of: after.effect(id: id)!, in: after, of: timeline, base: nil, reads: []) != before)
    }

    @Test func aRunMadeFromAHeldDragGoesIntoTheDragAndItsEndCommitsIt() async throws {
        let (f, id) = fixture()
        let state = ProjectState(f.project)
        func setInputA(_ value: Double) {
            var project = state.value
            project.editEffect(id, ofClip: f.clipID, in: f.timelineID) { effect in
                effect.changeControl(.inputA) { $0.number = AnimatedValue(ComponentValue(values: [value])) }
            }
            state.value = project
        }
        func opacity(_ project: EditingProject) -> AnimatedValue<ComponentValue> {
            project.clipAndLayer(f.clipID, in: f.timelineID)!.clip.effect(id: f.transformID)!.control(.opacity)!.number
        }
        // A step of dragging input A, held aside.
        state.beginHold()
        state.hold { setInputA(5) }
        let held = try #require(state.held)
        let job = ExpressionRunner.Job(timelineID: f.timelineID, clipID: f.clipID, effectID: id)
        let count = try #require(ExpressionRunner.request(for: job, in: held)).times.count
        let result = try #require(await ExpressionRunner(helper: FakeHelper(end: .samples((0..<count).map(Double.init)))).run(job, in: held))
        ExpressionResults.shared.store(result, for: id)
        let applied = state.applyExpressionResultsWhileHeld()
        #expect(applied)
        // The drag shows it; the project doesn't have it yet.
        let drag = try #require(state.held)
        #expect(!opacity(drag).keyframes.isEmpty)
        #expect(opacity(state.value).keyframes.isEmpty)
        // The drag ends: its last step is committed, and finds the result.
        state.endHold()
        setInputA(5)
        #expect(opacity(state.value) == opacity(held.applyingExpressionResults()))
        // Not held, nothing goes into a drag.
        #expect(!state.applyExpressionResultsWhileHeld())
    }

    @Test func theHelperMayReuseTheLastRunOnlyWhileWhatItReadIsUnchanged() async throws {
        var (f, id) = fixture()
        let job = ExpressionRunner.Job(timelineID: f.timelineID, clipID: f.clipID, effectID: id)
        // No run yet: nothing to start from.
        #expect(ExpressionRunner.request(for: job, in: f.project)?.request.fields["reuse"] == false)
        let count = try #require(ExpressionRunner.request(for: job, in: f.project)).times.count
        let rotation = KeyframingRead(timeline: f.timelineID, kind: .control(clip: f.clipID, effect: f.transformID, control: f.controlID(.rotation)))
        let helper = ReadingHelper(read: rotation, samples: (0..<count).map(Double.init))
        let result = try #require(await ExpressionRunner(helper: helper).run(job, in: f.project))
        #expect(result.reads == [rotation])
        ExpressionResults.shared.store(result, for: id)
        #expect(ExpressionRunner.request(for: job, in: f.project)?.request.fields["reuse"] == true)
        // What it read changes: the whole run again.
        let rotationID = f.controlID(.rotation)
        f.project.editEffect(f.transformID, ofClip: f.clipID, in: f.timelineID) { effect in
            effect.controls[effect.controlIndex(rotationID)!].number = AnimatedValue(ComponentValue(values: [45]))
        }
        #expect(ExpressionRunner.request(for: job, in: f.project)?.request.fields["reuse"] == false)
    }

    @Test func aPartialRunKeepsTheReadsOfTheRunBefore() async throws {
        let (f, id) = fixture()
        let job = ExpressionRunner.Job(timelineID: f.timelineID, clipID: f.clipID, effectID: id)
        let count = try #require(ExpressionRunner.request(for: job, in: f.project)).times.count
        let rotation = KeyframingRead(timeline: f.timelineID, kind: .control(clip: f.clipID, effect: f.transformID, control: f.controlID(.rotation)))
        let first = try #require(await ExpressionRunner(helper: ReadingHelper(read: rotation, samples: Array(repeating: 1, count: count))).run(job, in: f.project))
        ExpressionResults.shared.store(first, for: id)
        // This run reads nothing, as a partial one that called no sample
        // reading Rotation wouldn't.
        let second = try #require(await ExpressionRunner(helper: FakeHelper(end: .samples(Array(repeating: 2, count: count)))).run(job, in: f.project))
        #expect(second.reads == [rotation])
    }
}

/// A helper whose run reads one control, then gives `samples`.
final class ReadingHelper: ScriptHelper, @unchecked Sendable {
    let read: KeyframingRead
    let samples: [Double]

    init(read: KeyframingRead, samples: [Double]) {
        self.read = read
        self.samples = samples
    }

    func run(
        _ request: HelperRequest,
        output: @escaping @Sendable (ScriptOutput) -> Void,
        answer: @escaping @Sendable (HelperCall) async -> HelperReply
    ) async throws -> ScriptRunEnd {
        guard case .control(let clip, let effect, let control) = read.kind else { return .samples(samples) }
        let target: JSONValue = [
            "timeline": JSONValue(read.timeline), "clip": JSONValue(clip), "effect": JSONValue(effect), "control": JSONValue(control),
        ]
        _ = await answer(HelperCall(method: "control_frames", arguments: ["target": target]))
        return .samples(samples)
    }

    func stop() async {}

    func ping() async throws -> HelperPong { HelperPong(version: PythonVersion("3.14.0"), executable: "fake") }
}

private extension EditingProject {
    /// The project with the expression results that fit it written.
    func applyingExpressionResults() -> EditingProject {
        var project = self
        project.applyExpressionResults()
        return project
    }
}
