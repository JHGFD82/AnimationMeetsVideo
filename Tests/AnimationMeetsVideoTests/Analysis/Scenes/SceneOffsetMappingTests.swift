import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Scores are in the file's time; scenes, cuts, trims and hand edits are in
/// the original's. offset = fileTime − originalTime.
@MainActor
@Suite struct SceneOffsetMappingTests {
    private func sec(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 24_000) }
    private func range(_ a: Double, _ b: Double) -> CMTimeRange { CMTimeRange(start: sec(a), end: sec(b)) }

    /// An asset whose original was `original` seconds long and whose file
    /// now is `file` seconds long, aligned by `offset` seconds.
    private func project(original: Double = 10, file: Double? = nil, offset: Double = 0) -> (EditingProject, UUID) {
        var project = EditingProject.empty
        var asset = MediaClip(
            name: "Shot", kind: .video, url: nil, duration: sec(original),
            frameRate: 24, colorSpace: .rec709, codecName: "Test"
        )
        project.clips = [asset]
        if let file {
            asset.url = URL(fileURLWithPath: "/dev/null")
            project.clips = [asset]
            project.replaceMedia(
                id: asset.id,
                with: MediaClip(name: "R", kind: .video, url: URL(fileURLWithPath: "/etc/hosts"), duration: sec(file),
                                frameRate: 24, colorSpace: .rec709, codecName: "Test"),
                offset: sec(offset)
            )
        }
        return (project, asset.id)
    }

    /// 24 fps scores of a file `seconds` long with hard cuts at the given file times.
    private func track(seconds: Double, cuts: [Double]) -> ChangeScoreTrack {
        let count = Int(seconds * 24)
        let cutFrames = Set(cuts.map { Int(($0 * 24).rounded()) })
        return ChangeScoreTrack(
            timescale: 24, times: (0..<count).map(Int64.init),
            scores: (0..<count).map { $0 == 0 ? 0 : (cutFrames.contains($0) ? 200 : 2) }
        )
    }

    private func starts(_ scenes: [SceneRange]) -> [Double] { scenes.map { $0.start.seconds } }

    @Test func theConversionsAreInverses() {
        let mapping = OriginalTimeMapping(offset: sec(2))
        #expect(mapping.original(fromFile: sec(5)) == sec(3))
        #expect(mapping.file(fromOriginal: sec(3)) == sec(5))
        #expect(OriginalTimeMapping(offset: sec(-2)).original(fromFile: sec(5)) == sec(7))
    }

    // MARK: Offsets

    @Test func aPositiveOffsetMovesCutsEarlierInOriginalTime() throws {
        let (project, id) = project(original: 10, file: 12, offset: 2)
        let coverage = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 12, cuts: [5])))
        #expect(starts(coverage.scenes) == [0, 3])
        #expect(coverage.scenes.last?.end == sec(10))
        #expect(coverage.uncovered.isEmpty)
    }

    @Test func aNegativeOffsetMovesCutsLaterAndLeavesTheStartUncovered() throws {
        // Original t is at t − 2 s in the file, so original 0..2 s are before the file begins.
        let (project, id) = project(original: 10, file: 12, offset: -2)
        let coverage = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 12, cuts: [5])))
        // The file's 5 s is original 7 s; the scenes start where the footage does.
        #expect(starts(coverage.scenes) == [2, 7])
        #expect(coverage.scenes.last?.end == sec(10))
        #expect(coverage.uncovered == [range(0, 2)])
        #expect(!coverage.isComplete)
    }

    @Test func aLongerReplacementDoesNotExtendTheOriginalsDomain() throws {
        // The file runs 4 s past the original; a cut there is dropped, not clamped to the end.
        let (project, id) = project(original: 10, file: 14, offset: 0)
        let coverage = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 14, cuts: [4, 12])))
        #expect(starts(coverage.scenes) == [0, 4])
        #expect(coverage.scenes.last?.end == sec(10))
        #expect(coverage.uncovered.isEmpty)
    }

    @Test func aShorterReplacementOnlyGetsScenesWhereItHasFootage() throws {
        let (project, id) = project(original: 10, file: 6, offset: 0)
        let coverage = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 6, cuts: [4])))
        #expect(starts(coverage.scenes) == [0, 4])
        #expect(coverage.scenes.last?.end == sec(6))
        // The rest is reported, not filled with a scene.
        #expect(coverage.uncovered == [range(6, 10)])
    }

    @Test func aShorterReplacementWithAPositiveOffsetEndsEarlierInOriginalTime() throws {
        let (project, id) = project(original: 10, file: 6, offset: 1)
        let coverage = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 6, cuts: [])))
        #expect(coverage.usable == [range(0, 5)])
        #expect(coverage.uncovered == [range(5, 10)])
    }

    @Test func aReplacementThatDoesNotOverlapTheOriginalHasNoScenes() throws {
        let (project, id) = project(original: 10, file: 6, offset: 20)
        let coverage = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 6, cuts: [3])))
        #expect(coverage.scenes.isEmpty)
        #expect(coverage.hasNoOverlap)
        #expect(coverage.uncovered == [range(0, 10)])
        #expect(ClipsTabModel.coverageNote(coverage, replaced: true) != nil)
    }

    @Test func aReplacementBeforeTheOriginalHasNoScenesEither() throws {
        let (project, id) = project(original: 10, file: 6, offset: -20)
        let coverage = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 6, cuts: [3])))
        #expect(coverage.hasNoOverlap)
        #expect(project.scenes(ofAsset: id, track: track(seconds: 6, cuts: [3])).isEmpty)
    }

    @Test func cutsOutsideTheUsableStretchAreDiscardedNotClamped() throws {
        let (project, id) = project(original: 10, file: 12, offset: -2)
        // File cuts at 1 s (original 3... no: 1 − (−2) = 3) and 11.5 s (original 13.5, outside).
        let coverage = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 12, cuts: [1, 11.5])))
        #expect(starts(coverage.scenes) == [2, 3])
        #expect(coverage.scenes.allSatisfy { $0.end <= sec(10) })
    }

    @Test func anUnreplacedAssetIsAsBefore() throws {
        let (project, id) = project(original: 10)
        let coverage = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 10, cuts: [4])))
        #expect(starts(coverage.scenes) == [0, 4])
        #expect(coverage.scenes.last?.end == sec(10))
        #expect(coverage.isComplete)
    }

    @Test func anAssetReplacedBeforeTheOriginalsLengthWasKeptIsLimitedByTheFileOnly() throws {
        var (project, id) = project(original: 10, file: 14, offset: 0)
        project.clips[0].originalDuration = nil
        let coverage = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 14, cuts: [4])))
        #expect(coverage.scenes.last?.end == sec(14))
        #expect(coverage.uncovered.isEmpty)
    }

    // MARK: Trims

    @Test func aClipsTrimIsAnotherIntersection() throws {
        let (project, id) = project(original: 10, file: 12, offset: 2)
        let coverage = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 12, cuts: [5, 8])))
        // Cuts at 3 and 6 s (original). A clip trimmed to 2..7 s sees pieces of three scenes.
        let scenes = coverage.scenes(within: range(2, 7))
        #expect(scenes.map { [$0.start.seconds, $0.end.seconds] } == [[2, 3], [3, 6], [6, 7]])
        #expect(coverage.scenes(within: range(11, 12)).isEmpty)
    }

    // MARK: Edits in original time

    @Test func anIgnoredCutIsMatchedInOriginalTime() throws {
        var (project, id) = project(original: 10, file: 12, offset: 2)
        project.editScenes(ofAsset: id) { $0.ignoredCuts = [sec(3)] }
        let coverage = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 12, cuts: [5])))
        #expect(starts(coverage.scenes) == [0])
    }

    @Test func aSensitivityRegionIsReadInOriginalTime() throws {
        // A weak change at file 5 s (original 3 s). A region around original 3 s that
        // raises the sensitivity finds it; one around the file's 5 s would not.
        var (project, id) = project(original: 10, file: 12, offset: 2)
        let weak = ChangeScoreTrack(
            timescale: 24, times: (0..<288).map(Int64.init),
            scores: (0..<288).map { $0 == 0 ? 0 : ($0 == 120 ? 12 : 1) }
        )
        #expect(starts(try #require(project.sceneCoverage(ofAsset: id, track: weak)).scenes) == [0])
        project.editScenes(ofAsset: id) { $0.applySensitivity(1, from: sec(2), to: sec(4)) }
        #expect(starts(try #require(project.sceneCoverage(ofAsset: id, track: weak)).scenes) == [0, 3])
    }

    // MARK: Snapping

    @Test func aHandPlacedCutSnapsToARealFrameOfTheFile() {
        // Original t is at t + 0.013 s in the file; the file's frames are on a 24 fps grid.
        let mapping = OriginalTimeMapping(offset: sec(0.013))
        let track = track(seconds: 4, cuts: [])
        let snapped = track.nearestFrameTime(toOriginal: sec(1.0), mapping: mapping)
        // Nearest file frame to 1.013 s is 1.0 s (frame 24), which is original 0.987 s.
        #expect(abs(snapped.seconds - 0.987) < 1e-6)
        #expect(mapping.file(fromOriginal: snapped) == track.time(at: 24))
    }

    @Test func snappingFollowsVariableFrameTimes() {
        // Frames 1/24 apart, then 1/12 apart from 1 s on.
        var times: [Int64] = Array(0..<24).map { $0 * 25 }       // timescale 600: 0, 25, … 575
        times += (0..<12).map { 600 + Int64($0) * 50 }
        let track = ChangeScoreTrack(timescale: 600, times: times, scores: [UInt8](repeating: 0, count: times.count))
        let mapping = OriginalTimeMapping(offset: CMTime(value: -100, timescale: 600))   // file = original − 1/6 s
        // Original 1.40 s is file 1.2333 s (740 ticks); frames near it are at 700 and 750.
        let snapped = track.nearestFrameTime(toOriginal: CMTime(seconds: 1.40, preferredTimescale: 600), mapping: mapping)
        #expect(mapping.file(fromOriginal: snapped) == CMTime(value: 750, timescale: 600))   // 1.25 s
        #expect(snapped == CMTime(value: 850, timescale: 600))
    }

    @Test func snappingNeverLeavesTheInterval() {
        let track = track(seconds: 4, cuts: [])
        let interval = CMTimeRange(start: sec(1.01), end: sec(1.09))
        // Nearest frame to 1.02 s is 1.0 s, outside; the one inside is 1.0417 s.
        let snapped = track.nearestFrameTime(toOriginal: sec(1.02), mapping: .identity, within: interval)
        #expect(snapped > interval.start && snapped < interval.end)
        // A time that isn't inside to begin with is left alone.
        #expect(track.nearestFrameTime(toOriginal: sec(2), mapping: .identity, within: interval) == sec(2))
        // And when no frame is inside, so is a time inside.
        let narrow = CMTimeRange(start: sec(1.005), end: sec(1.02))
        #expect(track.nearestFrameTime(toOriginal: sec(1.01), mapping: .identity, within: narrow) == sec(1.01))
    }

    // MARK: Replacement then replacement

    @Test func aSecondReplacementWithAnotherOffsetMapsFromTheOriginalAgain() throws {
        var (project, id) = project(original: 10, file: 12, offset: 2)
        let first = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 12, cuts: [5])))
        #expect(starts(first.scenes) == [0, 3])

        project.replaceMedia(
            id: id,
            with: MediaClip(name: "R2", kind: .video, url: URL(fileURLWithPath: "/etc/shells"), duration: sec(11),
                            frameRate: 24, colorSpace: .rec709, codecName: "Test"),
            offset: sec(-1)
        )
        // The original's length survives; the second file's cut at 5 s is original 6 s.
        #expect(project.clips[0].originalDuration == sec(10))
        let second = try #require(project.sceneCoverage(ofAsset: id, track: track(seconds: 11, cuts: [5])))
        #expect(starts(second.scenes) == [1, 6])
        #expect(second.uncovered == [range(0, 1)])
        #expect(second.scenes.last?.end == sec(10))
    }

    @Test func theOriginalsLengthSurvivesSavingAndReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amv-offset-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "footage.mov")
        try Data("not really video".utf8).write(to: media)
        var project = EditingProject.empty
        let asset = MediaClip(name: "footage.mov", kind: .video, url: media, duration: sec(10), frameRate: 24, colorSpace: .rec709, codecName: "Stub")
        _ = project.importClip(asset, intoTimeline: project.rootTimelineID)
        project.replaceMedia(
            id: asset.id,
            with: MediaClip(name: "r", kind: .video, url: media, duration: sec(12), frameRate: 24, colorSpace: .rec709, codecName: "Stub"),
            offset: sec(2)
        )
        let package = root.appending(path: "Test.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(project, to: package)

        let loaded = try await ProjectStore.load(from: package) { url in
            MediaClip(name: url.lastPathComponent, kind: .video, url: url, duration: CMTime(seconds: 12, preferredTimescale: 24_000), frameRate: 24, colorSpace: .rec709, codecName: "Stub")
        }
        #expect(loaded.project.clips[0].originalDuration == sec(10))
        #expect(loaded.project.clips[0].alignmentOffset == sec(2))
    }
}
