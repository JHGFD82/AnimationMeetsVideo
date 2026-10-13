import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func t(_ frame: Int64) -> CMTime { CMTime(value: frame, timescale: 24) }

private func spikeTrack(frames: Int, spikes: [Int: UInt8]) -> ChangeScoreTrack {
    var scores = [UInt8](repeating: 2, count: frames)
    scores[0] = 0
    for (frame, value) in spikes { scores[frame] = value }
    return ChangeScoreTrack(timescale: 24, times: (0..<frames).map(Int64.init), scores: scores)
}

private func frames(_ times: [CMTime]) -> [Int64] { times.map { $0.value * 24 / Int64($0.timescale) } }

@Suite struct CutEditingTests {
    @Test func addingACutIsManual() {
        var edits = SceneEdits()
        edits.addCut(at: t(40))
        edits.addCut(at: t(40))
        #expect(edits.manualCuts == [t(40)])
    }

    @Test func removingAnAutoCutIgnoresItSoItStaysGone() {
        let track = spikeTrack(frames: 100, spikes: [30: 200, 70: 200])
        var edits = SceneEdits()
        let cut = SceneCut(time: t(30), origin: .auto)

        edits.removeCut(cut)
        edits.removeCut(cut)

        #expect(edits.ignoredCuts == [t(30)])
        let cuts = SceneDetector.cuts(in: track, defaultSensitivity: 0.5, edits: edits)
        #expect(frames(cuts.map(\.time)) == [70])
    }

    @Test func removingAManualCutDeletesIt() {
        var edits = SceneEdits()
        edits.addCut(at: t(40))
        edits.removeCut(SceneCut(time: t(40), origin: .manual))
        #expect(edits == SceneEdits())
    }

    @Test func addingBackAnIgnoredAutoCutRestoresIt() {
        var edits = SceneEdits()
        edits.removeCut(SceneCut(time: t(30), origin: .auto))
        edits.addCut(at: t(30))
        #expect(edits == SceneEdits())
    }

    @Test func movingACutRemovesTheOldOneAndAddsTheNew() {
        let track = spikeTrack(frames: 100, spikes: [30: 200])
        var edits = SceneEdits()
        edits.moveCut(SceneCut(time: t(30), origin: .auto), to: t(33))

        let cuts = SceneDetector.cuts(in: track, defaultSensitivity: 0.5, edits: edits)
        #expect(cuts == [SceneCut(time: t(33), origin: .manual)])
    }
}

@Suite struct SensitivityApplicationTests {
    @Test func raisingSensitivityOverASpanFindsMoreCutsOnlyThere() {
        let track = spikeTrack(frames: 300, spikes: [50: 200, 120: 20, 250: 20])
        var edits = SceneEdits()
        edits.applySensitivity(0.9, from: t(100), to: t(200))

        let cuts = SceneDetector.cuts(in: track, defaultSensitivity: 0.5, edits: edits)
        #expect(frames(cuts.map(\.time)) == [50, 120])
    }

    @Test func loweringSensitivityMergesInsideButKeepsTheEdges() {
        let track = spikeTrack(frames: 300, spikes: [50: 60, 100: 60, 150: 60, 200: 60])
        var edits = SceneEdits()
        edits.applySensitivity(0, from: t(50), to: t(200))

        let cuts = SceneDetector.cuts(in: track, defaultSensitivity: 0.5, edits: edits)
        #expect(frames(cuts.map(\.time)) == [50, 200])
    }

    @Test func manualCutsInsideTheSpanSurvive() {
        let track = spikeTrack(frames: 300, spikes: [50: 60, 150: 60, 200: 60])
        var edits = SceneEdits()
        edits.addCut(at: t(120))
        edits.applySensitivity(0, from: t(50), to: t(200))

        let cuts = SceneDetector.cuts(in: track, defaultSensitivity: 0.5, edits: edits)
        #expect(frames(cuts.map(\.time)) == [50, 120, 200])
    }

    @Test func ignoredCutsInsideTheSpanComeBackButOutsideStayIgnored() {
        var edits = SceneEdits()
        edits.removeCut(SceneCut(time: t(120), origin: .auto))
        edits.removeCut(SceneCut(time: t(40), origin: .auto))
        edits.applySensitivity(0.5, from: t(100), to: t(200))
        #expect(edits.ignoredCuts == [t(40)])
    }

    @Test func reapplyingOverTheSameSpanReplacesTheOldRegion() {
        var edits = SceneEdits()
        edits.applySensitivity(0.2, from: t(100), to: t(200))
        edits.applySensitivity(0.8, from: t(100), to: t(200))
        edits.applySensitivity(0.4, from: t(90), to: t(210))
        #expect(edits.regions.map(\.value) == [0.4])
    }

    @Test func aLargerRegionKeepsRegionsItDoesNotFullyCover() {
        var edits = SceneEdits()
        edits.applySensitivity(0.2, from: t(100), to: t(300))
        edits.applySensitivity(0.8, from: t(150), to: t(200))
        #expect(edits.regions.map(\.value) == [0.2, 0.8])
    }

    @Test func valuesAreClampedToTheSliderRange() {
        var edits = SceneEdits()
        edits.applySensitivity(7, from: t(0), to: t(10))
        #expect(edits.regions[0].value == 1)
    }
}

@Suite struct NearestFrameTests {
    private let track = ChangeScoreTrack(timescale: 1000, times: [0, 100, 250, 400], scores: [0, 1, 1, 1])

    @Test func snapsToTheClosestFrame() {
        #expect(track.nearestFrameTime(to: CMTime(value: 120, timescale: 1000)) == CMTime(value: 100, timescale: 1000))
        #expect(track.nearestFrameTime(to: CMTime(value: 200, timescale: 1000)) == CMTime(value: 250, timescale: 1000))
        #expect(track.nearestFrameTime(to: CMTime(value: 9_999, timescale: 1000)) == CMTime(value: 400, timescale: 1000))
        #expect(track.nearestFrameTime(to: CMTime(value: -5, timescale: 1000)) == CMTime(value: 0, timescale: 1000))
    }

    @Test func worksAcrossTimescales() {
        #expect(track.nearestFrameTime(to: CMTime(value: 1, timescale: 4)) == CMTime(value: 250, timescale: 1000))
    }

    @Test func emptyTrackLeavesTheTimeAlone() {
        let empty = ChangeScoreTrack(timescale: 600, times: [], scores: [])
        #expect(empty.nearestFrameTime(to: t(5)) == t(5))
    }
}

@Suite struct SceneTimelineTests {
    private func project() -> (EditingProject, UUID) {
        var project = EditingProject.empty
        let asset = MediaClip(name: "Long", kind: .video, url: nil, duration: CMTime(value: 100, timescale: 24),
                              frameRate: 24, colorSpace: .rec709, codecName: "Test")
        project.clips = [asset]
        return (project, asset.id)
    }

    @Test func anUnanalyzedAssetIsOneScene() {
        let (project, id) = project()
        let scenes = project.scenes(ofAsset: id, track: nil)
        #expect(scenes.count == 1)
        #expect(scenes[0].start == .zero)
        #expect(scenes[0].end == t(100))
    }

    @Test func scenesFollowTheAssetsEditsAndProjectDefault() {
        var (project, id) = project()
        let track = spikeTrack(frames: 100, spikes: [30: 20, 70: 200])

        #expect(project.scenes(ofAsset: id, track: track).count == 2)
        project.defaultSensitivity = 0.9
        #expect(project.scenes(ofAsset: id, track: track).count == 3)
        project.editScenes(ofAsset: id) { $0.sensitivity = 0.5 }
        #expect(project.scenes(ofAsset: id, track: track).count == 2)
        project.editScenes(ofAsset: id) { $0.addCut(at: t(50)) }
        #expect(project.scenes(ofAsset: id, track: track).count == 3)
    }

    @Test func addedScenesGoBackToBackFromZeroOnOneNewLayer() throws {
        var (project, id) = project()
        let scenes = [
            SceneRange(start: t(10), end: t(34), origin: .auto),
            SceneRange(start: t(60), end: t(72), origin: .auto),
            SceneRange(start: t(0), end: t(5), origin: .manual),
        ]

        let timelineID = project.rootTimelineID
        let added = project.addScenes(scenes, ofAsset: id, intoTimeline: timelineID)
        let result = try #require(added)

        let layer = try #require(project.timelines[0].layers.first)
        #expect(layer.id == result.layerID)
        #expect(layer.clips.map(\.id) == result.clipIDs)
        #expect(layer.clips.map(\.startOffset) == [t(0), t(24), t(36)])
        #expect(layer.clips.map(\.trimStart) == [t(10), t(60), t(0)])
        #expect(layer.clips.map(\.trimEnd) == [t(34), t(72), t(5)])
        #expect(layer.clips.allSatisfy { $0.source == .media(id) })
    }

    @Test func addingScenesNeedsAKnownAssetAndTimeline() {
        var (project, id) = project()
        let scene = [SceneRange(start: .zero, end: t(5), origin: .auto)]
        #expect(project.addScenes(scene, ofAsset: UUID(), intoTimeline: project.rootTimelineID) == nil)
        #expect(project.addScenes(scene, ofAsset: id, intoTimeline: UUID()) == nil)
        #expect(project.addScenes([], ofAsset: id, intoTimeline: project.rootTimelineID) == nil)
        #expect(project.timelines[0].layers.isEmpty)
    }
}

@Suite struct SceneSelectionTests {
    @Test func spanCoversTheEarliestStartToTheLatestEnd() throws {
        let scenes = [
            SceneRange(start: t(50), end: t(80), origin: .auto),
            SceneRange(start: t(10), end: t(50), origin: .auto),
            SceneRange(start: t(120), end: t(150), origin: .manual),
        ]
        let span = try #require(scenes.span)
        #expect(span.start == t(10))
        #expect(span.end == t(150))
        #expect([SceneRange]().span == nil)
    }

    @Test func previewShowsTheSpanWithoutChangingTheProject() {
        var project = EditingProject.empty
        let asset = MediaClip(name: "A", kind: .video, url: nil, duration: t(300), frameRate: 24, colorSpace: .rec709, codecName: "Test")
        project.clips = [asset]
        let track = spikeTrack(frames: 300, spikes: [50: 200, 120: 20, 180: 20, 250: 200])
        let before = project

        let preview = project.scenesPreviewing(
            ofAsset: asset.id, track: track,
            applying: { $0.applySensitivity(0.9, from: t(50), to: t(250)) },
            within: (t(50), t(250))
        )

        #expect(preview.map(\.start) == [t(50), t(120), t(180)])
        #expect(preview.last?.end == t(250))
        #expect(project == before)
        #expect(project.scenes(ofAsset: asset.id, track: track).count == 3)
    }
}

@Suite struct EffectiveSensitivityTests {
    @Test func regionBeatsAssetOverrideBeatsProjectDefault() {
        var edits = SceneEdits()
        #expect(SceneDetector.sensitivity(at: t(60), defaultSensitivity: 0.5, edits: edits) == 0.5)
        edits.sensitivity = 0.7
        #expect(SceneDetector.sensitivity(at: t(60), defaultSensitivity: 0.5, edits: edits) == 0.7)
        edits.applySensitivity(0.2, from: t(50), to: t(100))
        #expect(SceneDetector.sensitivity(at: t(60), defaultSensitivity: 0.5, edits: edits) == 0.2)
        #expect(SceneDetector.sensitivity(at: t(50), defaultSensitivity: 0.5, edits: edits) == 0.7)
    }
}

@Suite struct SceneDragPayloadTests {
    @Test func roundTripsThroughText() throws {
        let id = UUID()
        let scenes = [
            SceneRange(start: CMTime(value: 1001, timescale: 24000), end: CMTime(value: 5, timescale: 1), origin: .auto),
            SceneRange(start: CMTime(value: 5, timescale: 1), end: CMTime(value: 9, timescale: 1), origin: .manual),
        ]

        let payload = try #require(SceneDragPayload(text: SceneDragPayload(assetID: id, scenes: scenes).text))

        #expect(payload.assetID == id)
        #expect(payload.scenes.map(\.start) == scenes.map(\.start))
        #expect(payload.scenes.map(\.end) == scenes.map(\.end))
    }

    @Test func ordinaryTextIsNotAPayload() {
        #expect(SceneDragPayload(text: "hello") == nil)
        #expect(SceneDragPayload(text: "amv-scenes:{}") == nil)
        #expect(SceneDragPayload(text: "amv-scenes:not json") == nil)
    }

    @Test func rejectsZeroTimescales() {
        let text = "amv-scenes:{\"assetID\":\"\(UUID().uuidString)\",\"entries\":[{\"endScale\":0,\"endValue\":1,\"startScale\":24,\"startValue\":0}]}"
        #expect(SceneDragPayload(text: text) == nil)
    }
}
