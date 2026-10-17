import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// 24 fps track where `spikes` maps a frame index to its change score and
/// every other frame has a small score.
private func makeTrack(frames: Int, spikes: [Int: UInt8], quiet: UInt8 = 3) -> ChangeScoreTrack {
    ChangeScoreTrack(
        timescale: 24,
        times: (0..<frames).map(Int64.init),
        scores: (0..<frames).map { $0 == 0 ? 0 : (spikes[$0] ?? quiet) }
    )
}

private func frames(_ cuts: [CMTime]) -> [Int64] { cuts.map(\.value) }

@Suite struct SensitivityThresholdTests {
    @Test func higherSensitivityNeedsASmallerChange() {
        let strict = SceneDetector.threshold(forSensitivity: 0)
        let balanced = SceneDetector.threshold(forSensitivity: SceneDetector.balancedSensitivity)
        let loose = SceneDetector.threshold(forSensitivity: 1)
        #expect(strict > balanced && balanced > loose)
        #expect(abs(balanced - 0.11) < 0.01)
    }

    @Test func outOfRangeSensitivityIsClamped() {
        #expect(SceneDetector.threshold(forSensitivity: -5) == SceneDetector.threshold(forSensitivity: 0))
        #expect(SceneDetector.threshold(forSensitivity: 5) == SceneDetector.threshold(forSensitivity: 1))
    }
}

@Suite struct AutoCutTests {
    @Test func findsHardCutsAtTheFirstFrameOfTheNewScene() {
        let track = makeTrack(frames: 100, spikes: [30: 200, 70: 180])
        let cuts = SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5)
        #expect(frames(cuts) == [30, 70])
    }

    @Test func ignoresSmallChangesLikeMotion() {
        let track = makeTrack(frames: 100, spikes: [40: 15, 60: 20])
        #expect(SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5).isEmpty)
    }

    @Test func aSteadyShotHasNoCuts() {
        #expect(SceneDetector.autoCuts(in: makeTrack(frames: 200, spikes: [:]), defaultSensitivity: 1).isEmpty)
    }

    @Test func raisingSensitivityFindsMoreCuts() {
        let track = makeTrack(frames: 100, spikes: [30: 200, 60: 20])
        #expect(frames(SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5)) == [30])
        #expect(frames(SceneDetector.autoCuts(in: track, defaultSensitivity: 0.8)) == [30, 60])
    }

    @Test func aPlateauOfChangeIsOneCutAtItsPeak() {
        let track = makeTrack(frames: 100, spikes: [49: 90, 50: 140, 51: 90])
        #expect(frames(SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5)) == [50])
    }

    @Test func cutsCloserThanTheMinimumSceneKeepTheStrongerOne() {
        let track = makeTrack(frames: 100, spikes: [50: 120, 54: 220])
        #expect(frames(SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5)) == [54])
    }

    @Test func tinyTracksHaveNoCuts() {
        #expect(SceneDetector.autoCuts(in: makeTrack(frames: 2, spikes: [1: 255]), defaultSensitivity: 1).isEmpty)
    }

    @Test func variableFrameRateUsesRealTimestamps() {
        let track = ChangeScoreTrack(timescale: 1000, times: [0, 100, 200, 5_000, 5_100], scores: [0, 3, 3, 200, 3])
        let cuts = SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5)
        #expect(cuts.count == 1)
        #expect(cuts[0].seconds == 5)
    }
}

@Suite struct SensitivityRegionTests {
    private let track = makeTrack(frames: 300, spikes: [50: 200, 120: 20, 180: 20, 250: 20])

    private func region(_ start: Int64, _ end: Int64, _ value: Double) -> SensitivityRegion {
        SensitivityRegion(start: CMTime(value: start, timescale: 24), end: CMTime(value: end, timescale: 24), value: value)
    }

    @Test func aRegionOnlyChangesCutsInsideIt() {
        var edits = SceneEdits()
        edits.regions = [region(100, 200, 0.9)]

        let cuts = SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5, edits: edits)
        #expect(frames(cuts) == [50, 120, 180])
    }

    @Test func aRegionCanLowerSensitivityToMergeScenes() {
        let moderate = makeTrack(frames: 300, spikes: [50: 60, 200: 60])
        var edits = SceneEdits()
        edits.regions = [region(0, 100, 0)]

        let cuts = SceneDetector.autoCuts(in: moderate, defaultSensitivity: 0.5, edits: edits)
        #expect(frames(cuts) == [200])
    }

    @Test func theCutsAtBothEdgesOfARegionKeepTheirSensitivity() {
        var edits = SceneEdits()
        edits.regions = [region(100, 120, 1)]
        #expect(!frames(SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5, edits: edits)).contains(120))

        let strongEdges = makeTrack(frames: 300, spikes: [100: 200, 150: 60, 200: 200])
        edits.regions = [region(100, 200, 0)]
        #expect(frames(SceneDetector.autoCuts(in: strongEdges, defaultSensitivity: 0.5, edits: edits)) == [100, 200])
    }

    @Test func laterRegionsWinWhereTheyOverlap() {
        var edits = SceneEdits()
        edits.regions = [region(100, 200, 1), region(110, 130, 0)]
        #expect(frames(SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5, edits: edits)) == [50, 180])
    }

    @Test func assetOverrideReplacesTheProjectDefault() {
        var edits = SceneEdits()
        edits.sensitivity = 0.9
        #expect(SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5, edits: edits).count == 4)
    }
}

@Suite struct SceneListTests {
    private let duration = CMTime(value: 100, timescale: 24)

    @Test func manualCutsAreAddedAndIgnoredCutsRemoved() {
        let track = makeTrack(frames: 100, spikes: [30: 200, 70: 200])
        var edits = SceneEdits()
        edits.ignoredCuts = [CMTime(value: 30, timescale: 24)]
        edits.manualCuts = [CMTime(value: 50, timescale: 24)]

        let cuts = SceneDetector.cuts(in: track, defaultSensitivity: 0.5, edits: edits)
        #expect(cuts.map(\.time.value) == [50, 70])
        #expect(cuts.map(\.origin) == [.manual, .auto])
    }

    @Test func ignoredCutsMatchByTimeAcrossTimescales() {
        let track = makeTrack(frames: 100, spikes: [30: 200])
        var edits = SceneEdits()
        edits.ignoredCuts = [CMTime(value: 60, timescale: 48)]
        #expect(SceneDetector.cuts(in: track, defaultSensitivity: 0.5, edits: edits).isEmpty)
    }

    @Test func manualCutsSurviveWithoutAnyScores() {
        var edits = SceneEdits()
        edits.manualCuts = [CMTime(value: 40, timescale: 24)]
        let cuts = SceneDetector.cuts(in: nil, defaultSensitivity: 0.5, edits: edits)
        #expect(cuts.count == 1)
    }

    @Test func scenesCoverTheWholeAssetWithoutGaps() {
        let cuts = [
            SceneCut(time: CMTime(value: 30, timescale: 24), origin: .auto),
            SceneCut(time: CMTime(value: 70, timescale: 24), origin: .manual),
        ]
        let scenes = SceneDetector.scenes(from: cuts, duration: duration)
        #expect(scenes.map(\.start.value) == [0, 30, 70])
        #expect(scenes.map(\.end.value) == [30, 70, 100])
        #expect(scenes.map(\.origin) == [.auto, .auto, .manual])
        #expect(scenes.map(\.duration.value) == [30, 40, 30])
    }

    @Test func noCutsMeansOneSceneForTheWholeFile() {
        let scenes = SceneDetector.scenes(from: [], duration: duration)
        #expect(scenes.count == 1)
        #expect(scenes[0].start == .zero && scenes[0].end == duration)
    }

    @Test func cutsOutsideTheAssetAreIgnored() {
        let cuts = [
            SceneCut(time: .zero, origin: .manual),
            SceneCut(time: duration, origin: .manual),
            SceneCut(time: CMTime(value: 500, timescale: 24), origin: .manual),
        ]
        #expect(SceneDetector.scenes(from: cuts, duration: duration).count == 1)
    }
}

@Suite struct ChangeScoreTrackTests {
    @Test func roundTripsThroughBinaryForm() throws {
        let track = ChangeScoreTrack(timescale: 24000, times: [0, 1001, 2002, 3003], scores: [0, 7, 255, 12])
        let decoded = try ChangeScoreTrack(decoding: track.encoded())
        #expect(decoded == track)
    }

    @Test func roundTripsSkipScores() throws {
        let track = ChangeScoreTrack(
            timescale: 24, times: [0, 1, 2, 3], scores: [0, 7, 255, 250], skipScores: [0, 0, 250, 4]
        )
        #expect(try ChangeScoreTrack(decoding: track.encoded()) == track)
    }

    @Test func aTrackWithoutSkipScoresStaysWithoutThem() throws {
        // Saved before skip scores existed: it reads back as not having any,
        // rather than as all zeros, which would read as flashes.
        let track = ChangeScoreTrack(timescale: 24, times: [0, 1, 2], scores: [0, 9, 9])
        #expect(try ChangeScoreTrack(decoding: track.encoded()).skipScores == nil)
    }

    @Test func skipScoresForTheFirstTwoFramesAreRejected() {
        let track = ChangeScoreTrack(timescale: 24, times: [0, 1, 2], scores: [0, 9, 9], skipScores: [0, 5, 9])
        #expect(throws: ChangeScoreTrackError.self) { try ChangeScoreTrack(decoding: track.encoded()) }
    }

    @Test func usesOneByteOfScorePerFrame() {
        let frames = 1_000
        let track = ChangeScoreTrack(timescale: 1, times: (0..<Int64(frames)).map { $0 }, scores: Array(repeating: 0, count: frames))
        // Header, then 9 bytes a frame, then the (empty) list of empty spans.
        #expect(track.encoded().count == 4 + 4 + 4 + 4 + frames * 9 + 4)
    }

    @Test func rejectsOtherFilesAndDamage() throws {
        #expect(throws: ChangeScoreTrackError.self) { try ChangeScoreTrack(decoding: Data("nope".utf8)) }
        let good = ChangeScoreTrack(timescale: 24, times: [0, 1], scores: [0, 9]).encoded()
        #expect(throws: ChangeScoreTrackError.self) { try ChangeScoreTrack(decoding: good.dropLast()) }
        #expect(throws: ChangeScoreTrackError.self) { try ChangeScoreTrack(decoding: Data()) }
    }
}
