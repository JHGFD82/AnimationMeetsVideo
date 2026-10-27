import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Fixtures for the Clips tab's model and interaction tests: assets, the
/// scenes found in them, and the snapshot made of them.
enum ClipsTabFixtures {
    static func s(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    static func clip(_ name: String, _ kind: MediaKind = .video, seconds: Double = 20, frameRate: Double = 24) -> MediaClip {
        MediaClip(name: name, kind: kind, url: nil, duration: s(seconds), frameRate: frameRate, colorSpace: .rec709, codecName: "T")
    }

    static let track = ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 0])

    /// Scenes starting at each of `cuts` (the first at 0) and running to
    /// the next, or to `end`; the ones in `manual` set by hand.
    static func coverage(cuts: [Double], end: Double, manual: Set<Double> = [], uncovered: [CMTimeRange] = []) -> SceneCoverage {
        let scenes = zip(cuts, cuts.dropFirst() + [end]).map { start, end in
            SceneRange(start: s(start), end: s(end), origin: manual.contains(start) ? .manual : .auto)
        }
        return SceneCoverage(scenes: scenes, usable: [CMTimeRange(start: .zero, end: s(end))], uncovered: uncovered)
    }

    /// A snapshot of `clips`, in that order, with the scenes in `found` for
    /// the videos that have scores (`scored`).
    static func snapshot(
        _ clips: [MediaClip], scored: Set<UUID>? = nil, found: [UUID: SceneCoverage] = [:]
    ) -> ClipsTabModel.Snapshot {
        let scored = scored ?? Set(found.keys)
        let tracks = Dictionary(uniqueKeysWithValues: scored.map { ($0, track) })
        return ClipsTabModel.makeSnapshot(clips: clips, sort: .added, tracks: tracks) { clip, _ in found[clip.id] }
    }
}

@Suite struct ClipsTabModelTests {
    private typealias F = ClipsTabFixtures

    // MARK: - Snapshot

    @Test func soundUndetectedAndUnscoredVideosAreOneClipEach() {
        let song = F.clip("Song", .audio, frameRate: 0)
        var skipped = F.clip("Skipped")
        skipped.skipsSceneDetection = true
        let unscored = F.clip("Unscored")
        let coverage = F.coverage(cuts: [0, 10], end: 20)
        let snapshot = F.snapshot(
            [song, skipped, unscored], scored: [song.id, skipped.id], found: [song.id: coverage, skipped.id: coverage]
        )
        #expect(snapshot.order == [.asset(song.id), .asset(skipped.id), .asset(unscored.id)])
        #expect(snapshot.coverage.isEmpty)
        #expect(snapshot.entries.allSatisfy { $0.sceneNumber == nil && $0.duration == $0.clip.duration })
    }

    @Test func aVideoWithScenesFoundIsItsNumberedScenes() {
        let video = F.clip("Video")
        let snapshot = F.snapshot([video], found: [video.id: F.coverage(cuts: [0, 5, 12], end: 20, manual: [5])])
        #expect(snapshot.entries.map(\.sceneNumber) == [1, 2, 3])
        #expect(snapshot.entries.map(\.setByHand) == [false, true, false])
        #expect(snapshot.entries.map(\.start.seconds) == [0, 5, 12])
        #expect(snapshot.entries.map(\.seconds) == [5, 7, 8])
        #expect(snapshot.entriesByAsset[video.id]?.map(\.id) == snapshot.order)
        #expect(snapshot.scenes(of: video.id).count == 3)
    }

    // MARK: - Lines

    @Test func linesHeadOnlyVideosSplitIntoScenesAndGiveEachRowOfAStripALine() throws {
        let video = F.clip("Video", seconds: 20)
        let song = F.clip("Song", .audio, seconds: 20, frameRate: 0)
        let snapshot = F.snapshot([video, song], found: [video.id: F.coverage(cuts: [0, 10], end: 20)])
        let cell = CGSize(width: 96, height: 54)
        // Ten one-second thumbnails, three to a row: four rows a clip.
        let lines = ClipsTabModel.lines(snapshot: snapshot, used: [:]) {
            FilmstripLayout(duration: $0.seconds, interval: .oneSecond, cellSize: cell, width: 300)
        }
        let kinds = lines.map { line -> String in
            switch line {
            case .heading: "heading"
            case .title: "title"
            case .strip: "strip"
            case .note: "note"
            }
        }
        let clip = ["title", "strip", "strip", "strip", "strip"]
        let songClip = ["title"] + Array(repeating: "strip", count: 7)
        #expect(kinds == ["heading"] + clip + clip + songClip)
        #expect(Set(lines.map(\.id)).count == lines.count)
        let firstTitle = try #require(snapshot.order.first)
        #expect(lines[1].id == ClipsTabModel.Line.titleID(of: firstTitle))
    }

    @Test func aNoteFollowsOnlyScenesWithFootageMissing() {
        let whole = F.clip("Whole")
        let gappy = F.clip("Gappy")
        let snapshot = F.snapshot([whole, gappy], found: [
            whole.id: F.coverage(cuts: [0], end: 20),
            gappy.id: F.coverage(cuts: [0], end: 15, uncovered: [CMTimeRange(start: F.s(15), end: F.s(20))]),
        ])
        let lines = ClipsTabModel.lines(snapshot: snapshot, used: [:]) {
            FilmstripLayout(duration: $0.seconds, interval: .all, cellSize: CGSize(width: 96, height: 54), width: 300)
        }
        let notes = lines.compactMap { line -> UUID? in
            if case .note(let id, _) = line { return id }
            return nil
        }
        #expect(notes == [gappy.id])
    }

    @Test func aTitleSaysWhetherTheTimelinesUseItsStretch() {
        let video = F.clip("Video")
        let snapshot = F.snapshot([video], found: [video.id: F.coverage(cuts: [0, 10], end: 20)])
        let used = [video.id: [CMTimeRange(start: F.s(12), end: F.s(14))]]
        let lines = ClipsTabModel.lines(snapshot: snapshot, used: used) {
            FilmstripLayout(duration: $0.seconds, interval: .all, cellSize: CGSize(width: 96, height: 54), width: 300)
        }
        let titles = lines.compactMap { line -> Bool? in
            if case .title(_, let isUsed) = line { return isUsed }
            return nil
        }
        #expect(titles == [false, true])
    }

    // MARK: - Scenes

    private let scenes = ClipsTabFixtures.coverage(cuts: [0, 5, 10, 15], end: 20).scenes

    private func cutTimes(_ picked: [Int]) -> [Double] {
        ClipsTabModel.cutsToRemove(Set(picked.map { scenes[$0].id }), in: scenes).map(\.time.seconds)
    }

    @Test func theFirstSceneAloneHasNothingToMergeWith() {
        #expect(cutTimes([0]).isEmpty)
    }

    @Test func aLaterSceneAloneMergesWithTheOneBefore() {
        #expect(cutTimes([2]) == [10])
    }

    @Test func aRunOfScenesLosesTheCutsInsideIt() {
        #expect(cutTimes([1, 2, 3]) == [10, 15])
    }

    @Test func scenesApartLoseOnlyTheCutsAfterAPickedScene() {
        #expect(cutTimes([0, 2, 3]) == [15])
        #expect(cutTimes([0, 2]).isEmpty)
    }

    // MARK: - Picks

    @Test func aSceneOfAnAssetAlsoPickedWholeIsntDraggedTwice() {
        let video = F.clip("Video"), song = F.clip("Song", .audio, frameRate: 0)
        let snapshot = F.snapshot([video, song], found: [video.id: F.coverage(cuts: [0, 10], end: 20)])
        let scene = snapshot.order[1]
        // The video's own entry isn't listed once it is split, but a pick
        // can still name it (a drag of the heading's whole clip).
        let pieces = ClipsTabModel.dragPieces(for: [.asset(song.id), scene, .asset(video.id)], snapshot: snapshot)
        #expect(pieces.map(\.assetID) == [song.id])
        let scenesOnly = ClipsTabModel.dragPieces(for: [scene, .asset(song.id)], snapshot: snapshot)
        #expect(scenesOnly.map(\.assetID) == [video.id, song.id])
        #expect(scenesOnly[0].start.seconds == 10)
    }

    @Test func addingFromAClipWithARangeAddsTheRange() throws {
        let video = F.clip("Video")
        let snapshot = F.snapshot([video])
        var picked = BrowserSelection<BrowserItemID>()
        picked.setRange(of: .asset(video.id), from: 2, to: 6, duration: 20)
        let pieces = ClipsTabModel.piecesToAdd(from: .asset(video.id), snapshot: snapshot, picked: picked)
        let piece = try #require(pieces.first)
        #expect(pieces.count == 1)
        #expect(piece.start.seconds == 2)
        #expect(piece.end.seconds == 6)
    }

    @Test func addingFromAClipWithoutARangeAddsWhatIsSelected() {
        let a = F.clip("A"), b = F.clip("B"), c = F.clip("C")
        let snapshot = F.snapshot([a, b, c])
        var picked = BrowserSelection<BrowserItemID>()
        picked.commandClick(.asset(c.id))
        picked.commandClick(.asset(a.id))
        #expect(ClipsTabModel.piecesToAdd(from: .asset(c.id), snapshot: snapshot, picked: picked).map(\.assetID) == [a.id, c.id])
        #expect(ClipsTabModel.piecesToAdd(from: .asset(b.id), snapshot: snapshot, picked: picked).map(\.assetID) == [b.id])
    }

    @Test func onlyAssetsWithEveryClipPickedArePickedWhole() {
        let video = F.clip("Video"), song = F.clip("Song", .audio, frameRate: 0), other = F.clip("Other")
        let snapshot = F.snapshot([video, song, other], found: [video.id: F.coverage(cuts: [0, 10], end: 20)])
        var picked = BrowserSelection<BrowserItemID>()
        picked.selectAll(in: Array(snapshot.order.prefix(3)))
        #expect(ClipsTabModel.wholeAssetsPicked(snapshot: snapshot, picked: picked) == [video.id, song.id])
        picked.commandClick(snapshot.order[0])
        #expect(ClipsTabModel.wholeAssetsPicked(snapshot: snapshot, picked: picked) == [song.id])
        picked.setRange(of: .asset(song.id), from: 1, to: 2, duration: 20)
        #expect(ClipsTabModel.wholeAssetsPicked(snapshot: snapshot, picked: picked).isEmpty)
    }

    @Test func theSplitterShowsFromTheFirstPickToTheEndOfTheLastOfItsVideo() throws {
        let video = F.clip("Video"), song = F.clip("Song", .audio, frameRate: 0)
        let snapshot = F.snapshot([video, song], found: [video.id: F.coverage(cuts: [0, 5, 10, 15], end: 20)])
        let ids = [snapshot.order[1], .asset(song.id), snapshot.order[2]]
        let focus = try #require(ClipsTabModel.splitterFocus(for: ids, snapshot: snapshot))
        #expect(focus.assetID == video.id)
        #expect(focus.start.seconds == 5)
        #expect(focus.end.seconds == 15)
        #expect(ClipsTabModel.sceneIDs(ids, of: video.id).count == 2)
        #expect(ClipsTabModel.splitterFocus(for: [.asset(song.id)], snapshot: snapshot) == nil)
    }

    // MARK: - Text

    @Test func theClockShowsHoursFromAnHourOn() {
        #expect(ClipsTabModel.clock(75.5) == "1:15.50")
        #expect(ClipsTabModel.clock(4500) == "1:15:00.00")
    }

    @Test func soundWithoutAFrameRateCountsThirtyFramesASecond() {
        let song = BrowserEntry(id: .asset(UUID()), clip: F.clip("Song", .audio, frameRate: 0), start: .zero, duration: F.s(20))
        #expect(song.frameSeconds == 1.0 / 30)
        #expect(song.snapped(1.234) == 1.234)
    }

    // MARK: - Memo

    @MainActor @Test func aMemoWorksItsValueOutOnlyWhenItsKeyChanges() {
        let memo = Memo<Int, String>()
        var made = 0
        let make = { made += 1; return "value \(made)" }
        #expect(memo.value(for: 1, make: make) == "value 1")
        #expect(memo.value(for: 1, make: make) == "value 1")
        #expect(memo.revision == 1)
        #expect(memo.value(for: 2, make: make) == "value 2")
        #expect(memo.revision == 2)
        #expect(memo.latest == "value 2")
        #expect(made == 2)
    }
}
