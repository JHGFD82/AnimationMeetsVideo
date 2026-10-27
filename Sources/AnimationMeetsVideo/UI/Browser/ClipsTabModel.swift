import CoreGraphics
import CoreMedia
import Foundation

/// What the Clips tab lists and works out from the project, apart from the
/// view: the entries, the lines they are drawn as, and what a pick of them
/// means for adding, dragging, merging and removing. Each is a function of
/// what it is given, so the tab can keep it until that changes (`Memo`) and
/// tests can call it. See docs/browser.md.
enum ClipsTabModel {
    /// Everything listed, worked out once for each change to what it comes
    /// from and handed to what needs it, since scenes are costly to find.
    struct Snapshot {
        /// The assets in the order chosen (`BrowserSort`).
        var clips: [MediaClip] = []
        var entries: [BrowserEntry] = []
        var order: [BrowserItemID] = []
        var byID: [BrowserItemID: BrowserEntry] = [:]
        /// Each asset's clips, in browser order: the asset alone, or its scenes.
        var entriesByAsset: [UUID: [BrowserEntry]] = [:]
        /// Only for videos whose scenes are found.
        var coverage: [UUID: SceneCoverage] = [:]

        func scenes(of assetID: UUID) -> [SceneRange] { coverage[assetID]?.scenes ?? [] }
    }

    /// What a snapshot is worked out from. Scenes come from each asset, the
    /// project's sensitivity and the change scores (as `SceneCoverageCache`
    /// remembers them), so these decide when it is worked out again.
    /// Comparing them is cheap when nothing changed: arrays that share
    /// storage compare equal without being read.
    struct SnapshotKey: Equatable {
        var clips: [MediaClip]
        var sort: BrowserSort
        var defaultSensitivity: Double
        var tracks: [UUID: ChangeScoreTrack]
    }

    /// What the red lines under the strips are worked out from: the media
    /// (an effect's input reads its length) and the timelines.
    struct UsedKey: Equatable {
        var clips: [MediaClip]
        var timelines: [Timeline]
    }

    /// What the lines are worked out from, beyond the snapshot and the used
    /// ranges, which count as changed whenever their memos work them out again.
    struct LinesKey: Equatable {
        var snapshotRevision: Int
        var usedRevision: Int
        var width: CGFloat
        var interval: ThumbnailInterval
        var thumbnailSize: ThumbnailSize
    }

    enum LineID: Hashable {
        case heading(UUID)
        case title(BrowserItemID)
        case strip(BrowserItemID, row: Int, rowCount: Int)
        case note(UUID)
    }

    /// One line of the list: a video's name over its scenes, a clip's
    /// title, one row of its filmstrip, or a note under a video's scenes.
    /// Every line has an ID of its own, so a recycled line never shows
    /// another clip's title or pictures.
    enum Line: Identifiable, Equatable {
        case heading(MediaClip, sceneCount: Int)
        case title(BrowserEntry, isUsed: Bool)
        case strip(BrowserEntry, FilmstripLayout, row: Int, used: [SecondsSpan])
        case note(UUID, String)

        var id: LineID {
            switch self {
            case .heading(let clip, _): .heading(clip.id)
            case .title(let entry, _): Self.titleID(of: entry.id)
            case .strip(let entry, let layout, let row, _): .strip(entry.id, row: row, rowCount: layout.rowCount)
            case .note(let assetID, _): .note(assetID)
            }
        }

        static func titleID(of item: BrowserItemID) -> LineID { .title(item) }
    }

    // MARK: - Entries

    /// Every asset as one clip, or as its scenes when it is a video whose
    /// scenes are found (`coverage` gives them, given the asset's scores).
    static func makeSnapshot(
        clips: [MediaClip], sort: BrowserSort, tracks: [UUID: ChangeScoreTrack],
        coverage: (MediaClip, ChangeScoreTrack) -> SceneCoverage?
    ) -> Snapshot {
        var snapshot = Snapshot()
        snapshot.clips = sort.ordered(clips)
        for clip in snapshot.clips {
            guard clip.kind == .video, !clip.skipsSceneDetection, let track = tracks[clip.id],
                  let found = coverage(clip, track)
            else {
                snapshot.entries.append(BrowserEntry(id: .asset(clip.id), clip: clip, start: .zero, duration: clip.duration))
                continue
            }
            snapshot.coverage[clip.id] = found
            for (index, scene) in found.scenes.enumerated() {
                snapshot.entries.append(BrowserEntry(
                    id: .scene(asset: clip.id, scene: scene.id), clip: clip, start: scene.start, duration: scene.duration,
                    sceneNumber: index + 1, setByHand: scene.origin == .manual
                ))
            }
        }
        snapshot.order = snapshot.entries.map(\.id)
        snapshot.byID = Dictionary(snapshot.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        snapshot.entriesByAsset = Dictionary(grouping: snapshot.entries, by: \.clip.id)
        return snapshot
    }

    /// What the project's timelines use of each asset, for the red line.
    static func usedRanges(of clips: [MediaClip], in project: EditingProject) -> [UUID: [CMTimeRange]] {
        Dictionary(clips.map { ($0.id, project.usedRanges(ofMedia: $0.id)) }, uniquingKeysWith: { a, _ in a })
    }

    static func lines(
        snapshot: Snapshot, used: [UUID: [CMTimeRange]], layoutProvider layout: (BrowserEntry) -> FilmstripLayout
    ) -> [Line] {
        var lines: [Line] = []
        for clip in snapshot.clips {
            if let coverage = snapshot.coverage[clip.id] {
                lines.append(.heading(clip, sceneCount: coverage.scenes.count))
            }
            for entry in snapshot.entriesByAsset[clip.id] ?? [] {
                let usedHere = entry.seconds(within: used[entry.clip.id] ?? [])
                lines.append(.title(entry, isUsed: !usedHere.isEmpty))
                let layout = layout(entry)
                for row in 0..<layout.rowCount {
                    lines.append(.strip(entry, layout, row: row, used: usedHere))
                }
            }
            if let coverage = snapshot.coverage[clip.id], let note = coverageNote(coverage, replaced: clip.wasReplaced) {
                lines.append(.note(clip.id, note))
            }
        }
        return lines
    }

    // MARK: - Picks

    /// The assets the selection takes in whole, in browser order: each one
    /// with every clip of it selected (every scene, for a video split into
    /// them) and no range picked.
    static func wholeAssetsPicked(snapshot: Snapshot, picked: BrowserSelection<BrowserItemID>) -> [UUID] {
        guard picked.range == nil else { return [] }
        return snapshot.clips.map(\.id).filter { asset in
            let entries = snapshot.entriesByAsset[asset] ?? []
            return !entries.isEmpty && entries.allSatisfy { picked.contains($0.id) }
        }
    }

    /// The pieces for `ids`, in that order. A scene whose whole asset is
    /// also picked is left out, since the asset already carries it.
    static func dragPieces(for ids: [BrowserItemID], snapshot: Snapshot) -> [MediaPiece] {
        let wholeAssets = Set(ids.compactMap { id -> UUID? in
            if case .asset(let asset) = id { return asset }
            return nil
        })
        return ids.compactMap { id in
            if case .scene(let asset, _) = id, wholeAssets.contains(asset) { return nil }
            return snapshot.byID[id]?.piece()
        }
    }

    /// What Add to Timeline adds from `id`, from its menu, Return or
    /// VoiceOver: its range when it has one, else every selected clip when
    /// it is one of them, else it alone.
    static func piecesToAdd(from id: BrowserItemID, snapshot: Snapshot, picked: BrowserSelection<BrowserItemID>) -> [MediaPiece] {
        if let range = picked.range, range.item == id, let entry = snapshot.byID[id] {
            return [entry.piece(from: range.start, to: range.end)]
        }
        return dragPieces(for: picked.dragged(from: id, in: snapshot.order), snapshot: snapshot)
    }

    // MARK: - Scenes

    /// What the scene splitter shows for these picks: the stretch from the
    /// first to the end of the last of them that belong to the first one's
    /// video. Nil when that isn't a video.
    static func splitterFocus(for ids: [BrowserItemID], snapshot: Snapshot) -> SceneSplitter.Focus? {
        guard let first = ids.first.flatMap({ snapshot.byID[$0] }), first.clip.kind == .video else { return nil }
        let entries = ids.compactMap { snapshot.byID[$0] }.filter { $0.clip.id == first.clip.id }
        let start = entries.map(\.start).reduce(first.start, CMTimeMinimum)
        let end = entries.map { CMTimeAdd($0.start, $0.duration) }.reduce(CMTimeAdd(first.start, first.duration), CMTimeMaximum)
        return SceneSplitter.Focus(assetID: first.clip.id, start: start, end: end)
    }

    /// The scenes of `assetID` among `ids`.
    static func sceneIDs(_ ids: [BrowserItemID], of assetID: UUID) -> [String] {
        ids.compactMap { id in
            if case .scene(let asset, let scene) = id, asset == assetID { return scene }
            return nil
        }
    }

    /// The cuts whose removal joins the picked scenes: each picked scene's
    /// start, except where it begins the run (a single scene merges back into
    /// the one before it).
    static func cutsToRemove(_ sceneIDs: Set<String>, in all: [SceneRange]) -> [SceneCut] {
        let single = sceneIDs.count == 1
        var cuts: [SceneCut] = []
        for (index, scene) in all.enumerated() where sceneIDs.contains(scene.id) && index > 0 {
            if single || sceneIDs.contains(all[index - 1].id) {
                cuts.append(SceneCut(time: scene.start, origin: scene.origin))
            }
        }
        return cuts
    }

    // MARK: - Text

    /// The clip's duration, or a time in it, as a timecode at its own frame
    /// rate (as a clock without one).
    static func timecode(_ seconds: Double, _ entry: BrowserEntry) -> String {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return entry.clip.frameRate > 0 ? time.compactTimecode(frameRate: entry.clip.frameRate) : time.formatted
    }

    static func durationText(_ entry: BrowserEntry) -> String {
        timecode(entry.seconds, entry)
    }

    /// Says what the file the asset uses now can't play of the original's
    /// time, when it can't.
    static func coverageNote(_ coverage: SceneCoverage?, replaced: Bool) -> String? {
        guard let coverage else { return nil }
        if coverage.hasNoOverlap {
            return replaced ? "The replacement doesn't overlap the original's time, so there are no scenes." : "The file has no footage, so there are no scenes."
        }
        guard !coverage.uncovered.isEmpty else { return nil }
        let spans = coverage.uncovered.map { "\(clock($0.start.seconds))–\(clock($0.end.seconds))" }
        return "\(replaced ? "The replacement has" : "The file has") no footage for \(spans.joined(separator: ", "))."
    }

    /// "m:ss.ss", or "h:mm:ss.ss" from an hour on.
    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds), fraction = seconds.truncatingRemainder(dividingBy: 60)
        if whole >= 3600 {
            return String(format: "%d:%02d:%05.2f", whole / 3600, whole / 60 % 60, fraction)
        }
        return String(format: "%d:%05.2f", whole / 60, fraction)
    }

    /// "120 BPM", or "92–140 BPM" when the tempo changes noticeably.
    static func tempoText(_ beats: BeatTrack) -> String {
        if let range = beats.tempoRange, range.lowerBound > 0, range.upperBound / range.lowerBound > 1.04 {
            return "\(Int(range.lowerBound.rounded()))–\(Int(range.upperBound.rounded())) BPM"
        }
        return "\(Int(beats.beatsPerMinute.rounded())) BPM"
    }
}

extension BrowserEntry {
    /// One frame of the clip, in seconds. Sound and anything else without a
    /// frame rate counts 30 frames a second, so a drag too short to span
    /// one still picks the whole clip and Show in Clips Browser still
    /// rounds to it.
    var frameSeconds: Double {
        clip.frameRate > 0 ? 1 / clip.frameRate : 1.0 / 30
    }

    /// `seconds` on the nearest frame of the clip.
    func snapped(_ seconds: Double) -> Double {
        guard clip.frameRate > 0 else { return seconds }
        return min((seconds * clip.frameRate).rounded() / clip.frameRate, self.seconds)
    }
}

/// One value worked out from `Key` and kept until the key changes. Held in
/// a view's `@State` and asked from `body`, which can't set state: the
/// object stays the same from one redraw to the next, and SwiftUI doesn't
/// watch it, so keeping a value never redraws anything.
@MainActor
final class Memo<Key: Equatable, Value> {
    private var key: Key?
    /// The value last worked out, for what runs between redraws.
    private(set) var latest: Value?
    /// Goes up each time the value is worked out rather than kept, so what
    /// is worked out from it can be keyed on this instead of on the value.
    private(set) var revision = 0

    func value(for key: Key, make: () -> Value) -> Value {
        if let latest, self.key == key { return latest }
        let value = make()
        self.key = key
        latest = value
        revision += 1
        return value
    }
}
