import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 24_000) }

/// A 24 fps project with one video clip, four seconds long at the start of
/// Main, holding a Transform; for the bridge to read and change.
struct BridgeFixture {
    var project = EditingProject.empty
    let timelineID: UUID
    let layerID: UUID
    let clipID: UUID
    let assetID: UUID
    let transformID: UUID

    init() {
        let media = MediaClip(
            name: "A.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: seconds(20), frameRate: 24,
            colorSpace: .rec709, codecName: "H.264"
        )
        assetID = media.id
        timelineID = project.rootTimelineID
        let placed = project.importClip(media, intoTimeline: timelineID)!
        layerID = placed.layerID
        clipID = placed.clipID
        let id = clipID
        project.editClip(id, in: timelineID) { $0.trimStart = .zero; $0.trimEnd = seconds(4); $0.startOffset = .zero }
        transformID = project.addEffect(.transform, toClip: clipID, in: timelineID)!
    }

    var clip: TimelineClip { project.clipAndLayer(clipID, in: timelineID)!.clip }
    var transform: Effect { clip.effect(id: transformID)! }

    func controlID(_ kind: ControlKind) -> UUID { transform.control(kind)!.id }

    /// A control's `target` as the helper sends it.
    func target(_ kind: ControlKind) -> JSONValue {
        ["timeline": JSONValue(timelineID), "clip": JSONValue(clipID), "effect": JSONValue(transformID), "control": JSONValue(controlID(kind))]
    }

    var clipArguments: [String: JSONValue] { ["timeline": JSONValue(timelineID), "clip": JSONValue(clipID)] }
}

extension ProjectBridge {
    /// The value of a call that must succeed.
    func value(_ method: String, _ arguments: [String: JSONValue] = [:]) throws -> JSONValue {
        switch answer(HelperCall(method: method, arguments: arguments)) {
        case .value(let value): return value
        case .error(let error): throw error
        }
    }

    /// The error of a call that must fail.
    func error(_ method: String, _ arguments: [String: JSONValue] = [:]) -> ScriptCallError? {
        if case .error(let error) = answer(HelperCall(method: method, arguments: arguments)) { return error }
        return nil
    }
}

/// The `amv` module's reads, against the model: each answer is what the
/// editor shows for the same thing.
@Suite struct ProjectBridgeReadTests {
    @Test func theProjectListsItsTimelinesAndAssets() async throws {
        let f = BridgeFixture()
        let project = try await ProjectBridge(project: f.project).value("project")
        #expect(project["name"] == .string(f.project.name))
        #expect(project["root"] == JSONValue(f.timelineID))
        #expect(project["timelines"] == [JSONValue(f.timelineID)])
        #expect(project["assets"] == [JSONValue(f.assetID)])
    }

    @Test func aTimelineGivesExactTimes() async throws {
        let f = BridgeFixture()
        let timeline = try await ProjectBridge(project: f.project).value("timeline", ["timeline": JSONValue(f.timelineID)])
        #expect(timeline["name"] == "Main")
        #expect(timeline["frame"] == [1, 24])
        #expect(timeline["frame_rate"] == 24)
        #expect(timeline["layers"] == [JSONValue(f.layerID)])
        #expect(timeline["duration"] == ScriptTime.json(seconds(4)))
    }

    @Test func aLayerIsNamedAsTheTimelineShowsIt() async throws {
        let f = BridgeFixture()
        let layer = try await ProjectBridge(project: f.project).value("layer", ["timeline": JSONValue(f.timelineID), "layer": JSONValue(f.layerID)])
        #expect(layer["name"] == "Video 1" && layer["kind"] == "video")
        #expect(layer["clips"] == [[JSONValue(f.clipID), ScriptTime.json(.zero), ScriptTime.json(seconds(4))]])
    }

    @Test func aClipGivesItsPlaceSourceAndStacks() async throws {
        let f = BridgeFixture()
        let clip = try await ProjectBridge(project: f.project).value("clip", f.clipArguments)
        #expect(clip["layer"] == JSONValue(f.layerID))
        #expect(clip["source"] == ["kind": "media", "id": JSONValue(f.assetID)])
        #expect(clip["effects"] == [JSONValue(f.transformID)])
        #expect(clip["sound_effects"] == [])
        #expect(clip["end"] == ScriptTime.json(seconds(4)))
    }

    @Test func anEffectListsItsControlsByKindAndName() async throws {
        let f = BridgeFixture()
        var arguments = f.clipArguments
        arguments["effect"] = JSONValue(f.transformID)
        let effect = try await ProjectBridge(project: f.project).value("effect", arguments)
        #expect(effect["kind"] == "transform" && effect["name"] == "Transform")
        let controls = try #require(effect["controls"]?.array)
        #expect(controls.contains([JSONValue(f.controlID(.position)), "position", "Position"]))
    }

    @Test func aControlGivesItsValueAndKeyframes() async throws {
        var f = BridgeFixture()
        let id = f.controlID(.position)
        f.project.editEffect(f.transformID, ofClip: f.clipID, in: f.timelineID) { effect in
            effect.controls[effect.controlIndex(id)!].setComponent(0, to: 100, at: seconds(1))
            effect.controls[effect.controlIndex(id)!].number.setAnimated(true, at: seconds(1))
        }
        let control = try await ProjectBridge(project: f.project).value("control", ["target": f.target(.position)])
        #expect(control["kind"] == "position")
        #expect(control["driven_by"] == .null)
        let keyframes = try #require(control["keyframes"]?.array)
        #expect(keyframes.count == f.transform.control(.position)!.number.keyframes.count)
        let opacity = try await ProjectBridge(project: f.project).value("control", ["target": f.target(.opacity)])
        #expect(opacity["value"]?.number != nil)
    }

    @Test func aControlIsReadAtAnyMomentByTheModelsOwnCurve() async throws {
        var f = BridgeFixture()
        let id = f.controlID(.opacity)
        f.project.editEffect(f.transformID, ofClip: f.clipID, in: f.timelineID) { effect in
            let c = effect.controlIndex(id)!
            effect.controls[c].number = AnimatedValue(
                ComponentValue(values: [100]),
                keyframes: [Keyframe(time: .zero, value: ComponentValue(values: [0])), Keyframe(time: seconds(2), value: ComponentValue(values: [100]))]
            )
        }
        let values = try await ProjectBridge(project: f.project).value("control_at", ["target": f.target(.opacity), "times": [[1, 1]]])
        let expected = f.transform.control(.opacity)!.number.value(at: seconds(1)).values[0]
        #expect(values == [.number(expected)])
    }

    @Test func aClipsVolumeIsAControlWithNoEffect() async throws {
        let f = BridgeFixture()
        let target: JSONValue = ["timeline": JSONValue(f.timelineID), "clip": JSONValue(f.clipID), "property": "volume"]
        let volume = try await ProjectBridge(project: f.project).value("control", ["target": target])
        #expect(volume["kind"] == "volume" && volume["value"] == 0)
    }

    @Test func clipTimesMapBothWays() async throws {
        var f = BridgeFixture()
        let id = f.clipID
        f.project.editClip(id, in: f.timelineID) { $0.startOffset = seconds(2); $0.trimStart = seconds(1); $0.trimEnd = seconds(5) }
        let bridge = ProjectBridge(project: f.project)
        var arguments = f.clipArguments
        arguments["time"] = [3, 1]
        #expect(try await bridge.value("source_time", arguments) == ScriptTime.json(f.clip.sourceTime(atTimelineTime: seconds(3))))
        arguments["time"] = [2, 1]
        #expect(try await bridge.value("timeline_time", arguments) == ScriptTime.json(f.clip.timelineTime(forSourceTime: seconds(2))))
    }

    @Test func anAssetGivesItsNameKindAndDuration() async throws {
        let f = BridgeFixture()
        let asset = try await ProjectBridge(project: f.project).value("asset", ["asset": JSONValue(f.assetID)])
        #expect(asset["name"] == "A.mov" && asset["kind"] == "video" && asset["path"] == "/dev/null")
        #expect(asset["duration"] == ScriptTime.json(seconds(20)))
    }

    @Test func theDocumentIsTheProjectFile() async throws {
        let f = BridgeFixture()
        let document = try await ProjectBridge(project: f.project).value("document")
        #expect(document["id"] == JSONValue(f.project.id))
        #expect(document["timelines"]?.array?.count == 1)
    }

    @Test func somethingGoneRaisesGone() async throws {
        let f = BridgeFixture()
        let bridge = ProjectBridge(project: f.project)
        #expect(await bridge.error("clip", ["timeline": JSONValue(f.timelineID), "clip": JSONValue(UUID())])?.kind == .gone)
        #expect(await bridge.error("timeline", ["timeline": JSONValue(UUID())])?.kind == .gone)
        #expect(await bridge.error("no_such_call")?.kind == .value)
    }

    @Test func secondsAreRoundedToAFrameAndFractionsKeptExact() throws {
        let timeline = BridgeFixture().project.timelines[0]
        #expect(try ScriptTime.time(.number(0.51), in: timeline) == CMTime(value: 12, timescale: 24))
        #expect(try ScriptTime.time([1, 3], in: timeline) == CMTime(value: 1, timescale: 3))
        #expect(throws: ScriptCallError.self) { try ScriptTime.time(.number(.infinity), in: timeline) }
        #expect(throws: ScriptCallError.self) { try ScriptTime.time("soon", in: timeline) }
        // A fraction is bounded as seconds are (code-review-notes.md, F58).
        #expect(throws: ScriptCallError.self) { try ScriptTime.time([1e300, 3], in: timeline) }
        #expect(throws: ScriptCallError.self) { try ScriptTime.time([9_000_000_000_000_000, 1], in: timeline) }
    }

    @Test func theWindowsContextListsTheSelectionTopLayerFirst() async throws {
        let f = BridgeFixture()
        let context = await MainActor.run {
            let window = ScriptWindowState()
            window.timelineID = f.timelineID
            window.selection = TimelineSelection(timelineID: f.timelineID, layerID: f.layerID, timelineClipID: f.clipID)
            window.playhead = { CMTime(value: 3, timescale: 2) }
            return window.context(in: f.project)
        }
        #expect(context["timeline"] == JSONValue(f.timelineID))
        #expect(context["selection"] == [[JSONValue(f.timelineID), JSONValue(f.clipID)]])
        #expect(context["playhead"] == [3, 2])
    }
}
