import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 24_000) }

/// The `amv` module's changes, each against the editor call behind it, and
/// the refusals a change by hand would meet.
@Suite struct ProjectBridgeChangeTests {
    @Test func movingAClipIsMoveClip() async throws {
        let f = BridgeFixture()
        let bridge = ProjectBridge(project: f.project)
        var arguments = f.clipArguments
        arguments["time"] = [2, 1]
        _ = try await bridge.value("set_start", arguments)
        var expected = f.project
        expected.moveClip(f.clipID, in: f.timelineID, layer: f.layerID, to: seconds(2))
        #expect(await bridge.working.clipAndLayer(f.clipID, in: f.timelineID)?.clip == expected.clipAndLayer(f.clipID, in: f.timelineID)?.clip)
        // The snapshot is the project as the run began.
        #expect(await bridge.snapshot == f.project)
        #expect(await bridge.hasChanges)
    }

    @Test func readsAfterAChangeSeeIt() async throws {
        let f = BridgeFixture()
        let bridge = ProjectBridge(project: f.project)
        var arguments = f.clipArguments
        arguments["time"] = [1, 1]
        _ = try await bridge.value("set_trim_end", arguments)
        #expect(try await bridge.value("clip", f.clipArguments)["trim_end"] == [1, 1])
    }

    @Test func splittingGivesBothHalvesInOrder() async throws {
        let f = BridgeFixture()
        let bridge = ProjectBridge(project: f.project)
        var arguments = f.clipArguments
        arguments["time"] = [2, 1]
        let halves = try #require(try await bridge.value("split", arguments).array)
        #expect(halves.count == 2)
        let layer = try #require(await bridge.working.timeline(id: f.timelineID)?.layer(id: f.layerID))
        #expect(layer.clips.sorted { $0.startOffset < $1.startOffset }.map { JSONValue($0.id) } == halves)
        arguments["time"] = [9, 1]
        #expect(await bridge.error("split", arguments)?.kind == .gone)
    }

    @Test func aSplitOutsideTheClipIsAValueError() async throws {
        let f = BridgeFixture()
        var arguments = f.clipArguments
        arguments["time"] = [9, 1]
        #expect(await ProjectBridge(project: f.project).error("split", arguments)?.kind == .value)
    }

    @Test func addingAnEffectByKindOrName() async throws {
        let f = BridgeFixture()
        let bridge = ProjectBridge(project: f.project)
        var arguments = f.clipArguments
        arguments["kind"] = "color"
        let id = try #require(try await bridge.value("add_effect", arguments).uuid)
        #expect(await bridge.working.clipAndLayer(f.clipID, in: f.timelineID)?.clip.effect(id: id)?.kind == .color)
        arguments["kind"] = "Color"
        #expect(try await bridge.value("add_effect", arguments).uuid != nil)
        arguments["kind"] = "noSuchEffect"
        #expect(await bridge.error("add_effect", arguments)?.kind == .lookup)
    }

    @Test func settingAValueClampsItToTheControlsRange() async throws {
        let f = BridgeFixture()
        let bridge = ProjectBridge(project: f.project)
        _ = try await bridge.value("set_control", ["target": f.target(.opacity), "value": 1_000])
        let opacity = await bridge.working.clipAndLayer(f.clipID, in: f.timelineID)!.clip.effect(id: f.transformID)!.control(.opacity)!
        #expect(opacity.number.value.values[0] == ControlKind.opacity.clamped(1_000, index: 0))
        #expect(await bridge.error("set_control", ["target": f.target(.position), "value": [1, 2, 3]])?.kind == .value)
    }

    @Test func keyframesAreReplacedInOneCall() async throws {
        let f = BridgeFixture()
        let bridge = ProjectBridge(project: f.project)
        _ = try await bridge.value("set_keyframes", ["target": f.target(.opacity), "keyframes": [[[0, 1], 0], [[1, 1], 100]]])
        let number = await bridge.working.clipAndLayer(f.clipID, in: f.timelineID)!.clip.effect(id: f.transformID)!.control(.opacity)!.number
        #expect(number.keyframes.map(\.time) == [.zero, CMTime(value: 1, timescale: 1)])
        #expect(number.keyframes.map(\.value.values) == [[0], [100]])
        // A keyframed control's value isn't set by assigning it one.
        #expect(await bridge.error("set_control", ["target": f.target(.opacity), "value": 50])?.kind == .value)
    }

    @Test func drivenKeyframesAreRefusedUntilBakedAndTheWorkingCopyIsLeftAsItWas() async throws {
        let f = BridgeFixture()
        let bridge = ProjectBridge(project: f.project)
        let method = try #require(try await bridge.value("drive", ["target": f.target(.position), "method": "wiggler"]).uuid)
        let driven = await bridge.working
        let error = await bridge.error("set_keyframes", ["target": f.target(.position), "keyframes": []])
        #expect(error?.kind == .refused)
        #expect(await bridge.working == driven)
        #expect(try await bridge.value("control", ["target": f.target(.position)])["driven_by"] == JSONValue(method))
        _ = try await bridge.value("bake", ["target": f.target(.position)])
        _ = try await bridge.value("set_keyframes", ["target": f.target(.position), "keyframes": []])
    }

    @Test func aMethodsSettingsAreSetByKind() async throws {
        let f = BridgeFixture()
        let bridge = ProjectBridge(project: f.project)
        let method = try #require(try await bridge.value("drive", [
            "target": f.target(.position), "method": "wiggler", "settings": ["seed": 7],
        ]).uuid)
        let effect = await bridge.working.clipAndLayer(f.clipID, in: f.timelineID)!.clip.effect(id: method)!
        #expect(effect.control(.seed)?.number.value.values.first == ControlKind.seed.clamped(7, index: 0))
        #expect(await bridge.error("drive", ["target": f.target(.position), "method": "wiggler", "settings": ["nope": 1]])?.kind == .lookup)
    }

    @Test func aClipTheMotionDesignerHasOpenIsRefused() async throws {
        let f = BridgeFixture()
        let lock = ProjectState.ClipLock(timelineID: f.timelineID, clipIDs: [f.clipID])
        let bridge = ProjectBridge(project: f.project, context: ProjectBridge.Context(locks: [lock]))
        var arguments = f.clipArguments
        arguments["time"] = [2, 1]
        #expect(await bridge.error("set_start", arguments)?.kind == .refused)
        #expect(await !bridge.hasChanges)
        // Reading it is fine.
        #expect(try await bridge.value("clip", f.clipArguments)["start"] == ScriptTime.json(.zero))
    }

    @Test func renamingAndReorderingLayersAndTimelines() async throws {
        let f = BridgeFixture()
        let bridge = ProjectBridge(project: f.project)
        _ = try await bridge.value("set_layer_name", ["timeline": JSONValue(f.timelineID), "layer": JSONValue(f.layerID), "name": "Logo"])
        #expect(try await bridge.value("layer", ["timeline": JSONValue(f.timelineID), "layer": JSONValue(f.layerID)])["name"] == "Logo")
        _ = try await bridge.value("set_timeline_name", ["timeline": JSONValue(f.timelineID), "name": "Edit"])
        #expect(await bridge.working.timeline(id: f.timelineID)?.name == "Edit")
        #expect(await bridge.error("set_timeline_name", ["timeline": JSONValue(f.timelineID), "name": "  "])?.kind == .value)
        let added = try #require(try await bridge.value("add_timeline", ["name": "Titles"]).uuid)
        let titles = try #require(await bridge.working.timeline(id: added))
        #expect(titles.frameRate == 24 && titles.name == "Titles")
    }

    @Test func placingAnAssetPutsItOnANewTopLayer() async throws {
        let f = BridgeFixture()
        let bridge = ProjectBridge(project: f.project)
        let clip = try #require(try await bridge.value("place", ["timeline": JSONValue(f.timelineID), "asset": JSONValue(f.assetID)]).uuid)
        #expect(await bridge.working.timeline(id: f.timelineID)?.layers.first?.clips.first?.id == clip)
    }
}

/// A helper that makes the calls it is given and ends as it is told,
/// standing in for Python.
final class FakeHelper: ScriptHelper, @unchecked Sendable {
    let calls: [HelperCall]
    let end: ScriptRunEnd
    private(set) var replies: [HelperReply] = []

    init(calls: [HelperCall] = [], end: ScriptRunEnd = .finished(display: nil)) {
        self.calls = calls
        self.end = end
    }

    func run(
        _ request: HelperRequest,
        output: @escaping @Sendable (ScriptOutput) -> Void,
        answer: @escaping @Sendable (HelperCall) async -> HelperReply
    ) async throws -> ScriptRunEnd {
        for call in calls { replies.append(await answer(call)) }
        return end
    }

    func stop() async {}

    func ping() async throws -> HelperPong { HelperPong(version: PythonVersion("3.14.0"), executable: "fake") }
}

/// A run, end to end, without Python: its changes are one undo step named
/// for the script, and a run that raises writes nothing.
@MainActor @Suite struct ScriptRunnerTests {
    private func target(_ project: EditingProject) -> (ScriptTarget, ProjectState, ProjectHistory, UndoManager) {
        let state = ProjectState(project)
        let history = ProjectHistory(project: state.value)
        let undo = UndoManager()
        undo.groupsByEvent = false
        history.undoManager = undo
        let target = ScriptTarget(
            projectState: state, history: history, packageURL: nil, sceneTracks: [:], window: ScriptWindowState()
        )
        return (target, state, history, undo)
    }

    private func moveCall(_ f: BridgeFixture) -> HelperCall {
        var arguments = f.clipArguments
        arguments["time"] = [2, 1]
        return HelperCall(method: "set_start", arguments: arguments)
    }

    @Test func aRunIsOneUndoStepNamedForTheScript() async throws {
        let f = BridgeFixture()
        let (target, state, history, undo) = target(f.project)
        let runner = ScriptRunner(helper: FakeHelper(calls: [moveCall(f)]), transcript: ScriptTranscript())
        undo.beginUndoGrouping()
        let outcome = await runner.run(HelperRequest(kind: .script, code: ""), named: "Stagger", on: target)
        #expect(outcome == .finished(changed: true, display: nil))
        #expect(state.value.clipAndLayer(f.clipID, in: f.timelineID)?.clip.startOffset == seconds(2))
        // As the editor records each write.
        history.projectDidChange(state.value)
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Run \u{201C}Stagger\u{201D}")
    }

    @Test func aRunThatRaisesWritesNothing() async throws {
        let f = BridgeFixture()
        let (target, state, _, _) = target(f.project)
        let failure = ScriptFailure(exception: "ValueError", message: "no", line: 3)
        let runner = ScriptRunner(helper: FakeHelper(calls: [moveCall(f)], end: .failed(failure)), transcript: ScriptTranscript())
        #expect(await runner.run(HelperRequest(kind: .script, code: ""), named: "Broken", on: target) == .failed(failure))
        #expect(state.value == f.project)
    }

    @Test func aRunThatChangesNothingIsNoStep() async throws {
        let f = BridgeFixture()
        let (target, state, _, _) = target(f.project)
        let runner = ScriptRunner(helper: FakeHelper(calls: [HelperCall(method: "project")]), transcript: ScriptTranscript())
        #expect(await runner.run(HelperRequest(kind: .script, code: ""), named: "Look", on: target) == .finished(changed: false, display: nil))
        #expect(state.value == f.project)
    }
}
