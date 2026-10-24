import CoreMedia
import Foundation

/// How different each frame is from the one before it, for a whole video.
/// This is what detection saves, so changing sensitivity afterwards only
/// re-applies a threshold and never decodes the video again.
struct ChangeScoreTrack: Equatable, Sendable {
    /// Units per second for `times`.
    var timescale: Int32
    /// Presentation time of every frame, in `timescale` units, ascending.
    var times: [Int64]
    /// `scores[i]` is the picture change from frame `i - 1` to frame `i`,
    /// scaled so 255 is a completely different picture. `scores[0]` is 0.
    var scores: [UInt8]
    /// `skipScores[i]` is the picture change from frame `i - 2` to frame `i`,
    /// on the same scale: across frame `i - 1`, so a one-frame flash, which
    /// changes a lot into and out of itself, changes little across. 0 where
    /// there is no frame two back. Nil for tracks saved before they existed.
    var skipScores: [UInt8]?
    /// Stretches of the file's time that hold no footage (empty edits, such
    /// as the second before a late first picture), in `timescale` units,
    /// ascending and apart. No frame lies in one, and no change is scored
    /// across one: the first frame after it scores 0.
    var emptySpans: [EmptySpan] = []

    struct EmptySpan: Equatable, Sendable {
        var start: Int64
        var end: Int64
    }

    var frameCount: Int { times.count }

    func time(at index: Int) -> CMTime {
        CMTime(value: times[index], timescale: timescale)
    }

    // MARK: Serialization

    private static let magic: [UInt8] = Array("AMVS".utf8)
    /// 2 adds the empty spans after the scores. Version 1 files have none.
    /// 3 adds the skip scores between the scores and the spans; a track
    /// without them is still written as version 2.
    private static let version: UInt32 = 3

    /// Compact binary form: a header, then every frame time, then the scores
    /// (one byte per frame), then (version 3) the skip scores, one byte per
    /// frame, then the empty spans: a count and a start and end each. All
    /// integers are little endian.
    func encoded() -> Data {
        var data = Data(Self.magic)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(skipScores == nil ? 2 : Self.version)
        append(timescale)
        append(UInt32(times.count))
        for time in times { append(time) }
        data.append(contentsOf: scores)
        if let skipScores { data.append(contentsOf: skipScores) }
        append(UInt32(emptySpans.count))
        for span in emptySpans {
            append(span.start)
            append(span.end)
        }
        return data
    }

    init(timescale: Int32, times: [Int64], scores: [UInt8], skipScores: [UInt8]? = nil, emptySpans: [EmptySpan] = []) {
        precondition(times.count == scores.count, "one score per frame")
        precondition(skipScores.map { $0.count == times.count } ?? true, "one skip score per frame")
        self.timescale = timescale
        self.times = times
        self.scores = scores
        self.skipScores = skipScores
        self.emptySpans = emptySpans
    }

    init(decoding data: Data) throws {
        var offset = 0
        func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw ChangeScoreTrackError.truncated }
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: (data.startIndex + offset)..<(data.startIndex + offset + size)) }
            offset += size
            return T(littleEndian: value)
        }

        guard data.count >= Self.magic.count, Array(data.prefix(Self.magic.count)) == Self.magic else {
            throw ChangeScoreTrackError.notAScoreFile
        }
        offset = Self.magic.count
        let version = try read(UInt32.self)
        guard (1...Self.version).contains(version) else { throw ChangeScoreTrackError.unsupportedVersion(version) }
        let timescale = try read(Int32.self)
        let count = Int(try read(UInt32.self))
        let bytesPerFrame = version >= 3 ? 10 : 9
        guard timescale > 0, data.count - offset >= count * bytesPerFrame else { throw ChangeScoreTrackError.truncated }

        var times: [Int64] = []
        times.reserveCapacity(count)
        for _ in 0..<count { times.append(try read(Int64.self)) }
        let scores = [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
        offset += count
        var skipScores: [UInt8]?
        if version >= 3 {
            skipScores = [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
            offset += count
        }
        var spans: [EmptySpan] = []
        if version == 1 {
            guard offset == data.count else { throw ChangeScoreTrackError.truncated }
        } else {
            let spanCount = Int(try read(UInt32.self))
            guard data.count - offset == spanCount * 16 else { throw ChangeScoreTrackError.truncated }
            for _ in 0..<spanCount { spans.append(EmptySpan(start: try read(Int64.self), end: try read(Int64.self))) }
        }
        self.init(timescale: timescale, times: times, scores: scores, skipScores: skipScores, emptySpans: spans)
        try validate()
    }

    /// Checks the track against its documented format, so nothing downstream
    /// has to cope with a malformed one:
    /// - `timescale` is positive;
    /// - frame times are not negative and strictly increase (a frame whose
    ///   time repeats or goes back is an error, not something to sort away);
    /// - the first frame has no previous frame, so its score is 0, and
    ///   skip scores, when there are any, number one per frame and are 0
    ///   for the first two frames, which have no frame two back;
    /// - empty spans start at or after 0, are not empty themselves, ascend
    ///   without overlapping, and contain no frame.
    /// Every score value, 0 to 255, is valid. An empty track is valid.
    func validate() throws {
        guard timescale > 0 else { throw ChangeScoreTrackError.invalid("The time scale isn't positive.") }
        guard times.count == scores.count else { throw ChangeScoreTrackError.invalid("Frames and scores don't match.") }
        try validateEmptySpans()
        guard let first = times.first else { return }
        guard first >= 0 else { throw ChangeScoreTrackError.invalid("A frame time is negative.") }
        for index in 1..<max(times.count, 1) where times[index] <= times[index - 1] {
            throw ChangeScoreTrackError.invalid(
                times[index] == times[index - 1]
                    ? "Two frames have the same time."
                    : "Frame times don't increase."
            )
        }
        guard scores[0] == 0 else { throw ChangeScoreTrackError.invalid("The first frame has a score.") }
        if let skipScores {
            guard skipScores.count == times.count else { throw ChangeScoreTrackError.invalid("Frames and skip scores don't match.") }
            guard skipScores.prefix(2).allSatisfy({ $0 == 0 }) else {
                throw ChangeScoreTrackError.invalid("One of the first two frames has a skip score.")
            }
        }
    }

    private func validateEmptySpans() throws {
        var previousEnd: Int64 = 0
        for span in emptySpans {
            guard span.start >= previousEnd, span.end > span.start else {
                throw ChangeScoreTrackError.invalid("The empty stretches are out of order or overlap.")
            }
            previousEnd = span.end
        }
        for time in times where emptySpans.contains(where: { time >= $0.start && time < $0.end }) {
            throw ChangeScoreTrackError.invalid("A frame lies in an empty stretch.")
        }
    }
}

enum ChangeScoreTrackError: LocalizedError {
    case notAScoreFile
    case unsupportedVersion(UInt32)
    case truncated
    /// The frames or scores break the format (see `ChangeScoreTrack.validate`).
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): "The scene-change data isn't valid: \(reason)"
        case .notAScoreFile: "This isn't a scene-change data file."
        case .unsupportedVersion(let version): "Scene-change data version \(version) isn't supported."
        case .truncated: "The scene-change data file is damaged."
        }
    }
}

// MARK: - Sensitivity

/// A sensitivity applied to one stretch of an asset, set by the person
/// selecting scenes and moving the slider. It applies strictly between
/// `start` and `end`, so the cuts at the two edges keep the sensitivity they
/// had; later regions win where they overlap.
struct SensitivityRegion: Identifiable, Equatable, Sendable {
    var id = UUID()
    var start: CMTime
    var end: CMTime
    var value: Double
}

/// The hand-made part of an asset's scene list. Automatic cuts are not stored
/// here: they are recomputed from the saved change scores, so they follow the
/// sensitivity settings, while everything in this struct survives a re-detect.
struct SceneEdits: Equatable, Sendable {
    /// Overrides the project's default for this asset when set.
    var sensitivity: Double?
    var regions: [SensitivityRegion] = []
    /// Cuts the person added or moved a boundary to.
    var manualCuts: [CMTime] = []
    /// Automatic cuts the person removed, so they don't come back.
    var ignoredCuts: [CMTime] = []
}

struct SceneCut: Equatable, Sendable {
    enum Origin: String, Sendable { case auto, manual }
    /// Time of the first frame of the scene that starts here.
    var time: CMTime
    var origin: Origin
}

/// A stretch of an asset between two cuts. Scenes are only ranges of the
/// asset's own time; the media file is never split.
struct SceneRange: Identifiable, Equatable, Sendable {
    var start: CMTime
    var end: CMTime
    var origin: SceneCut.Origin

    var id: String { "\(start.value)/\(start.timescale)" }
    var duration: CMTime { CMTimeSubtract(end, start) }
}

// MARK: - Detection

enum SceneDetector {
    /// The default for a new project: a balanced setting.
    static let balancedSensitivity = 0.5
    /// Cuts closer together than this are treated as one; the stronger wins.
    static let minimumSceneSeconds = 0.4

    /// The smallest picture change counted as a cut, as a fraction of 255.
    /// Sensitivity 0 needs an almost total change; 1 reacts to small ones.
    /// Exponential so each step of the slider feels even.
    static func threshold(forSensitivity sensitivity: Double) -> Double {
        let s = sensitivity.clamped(to: 0...1)
        let strict = 0.4, loose = 0.03
        return strict * exp(log(loose / strict) * s)
    }

    /// The sensitivity in effect at `time`: the latest region around it, else
    /// the asset's override, else the project default.
    static func sensitivity(at time: CMTime, defaultSensitivity: Double, edits: SceneEdits) -> Double {
        edits.regions.last { region in
            CMTimeCompare(time, region.start) > 0 && CMTimeCompare(time, region.end) < 0
        }?.value ?? edits.sensitivity ?? defaultSensitivity
    }

    /// How many frames on each side of a frame make up the change around it.
    static let backgroundRadius = 4

    /// The usual change around frame `i`: the median of up to
    /// `backgroundRadius` scores on each side, leaving `i` itself out. A
    /// spike or two nearby doesn't move it, but a steady change does.
    private static func background(around i: Int, in scores: [UInt8]) -> Double {
        // The first frame scores 0 by definition, not by being still.
        let before = scores[max(1, i - backgroundRadius)..<i]
        let after = scores[min(i + 1, scores.count)..<min(i + 1 + backgroundRadius, scores.count)]
        let around = (Array(before) + Array(after)).sorted()
        guard !around.isEmpty else { return 0 }
        let middle = around.count / 2
        return around.count.isMultiple(of: 2)
            ? (Double(around[middle - 1]) + Double(around[middle])) / 2
            : Double(around[middle])
    }

    /// Whether frame `i` is a one-frame flash, or the frame just after one:
    /// the changes into the flash and out of it both rise to a cut (`limit`,
    /// in 0...255), but the change across it, from the frame before to the
    /// frame after, does not, so the shot goes on. A hard cut through one
    /// blended frame also changes twice in a row, but a lot across, so it
    /// stays a cut. Measured against one frame's usual change, a flash during
    /// a camera move may still cut. A track without skip scores can't tell.
    private static func isFlash(_ i: Int, in track: ChangeScoreTrack, limit: Double) -> Bool {
        guard let skips = track.skipScores else { return false }
        let scores = track.scores
        func rise(_ j: Int) -> Double { Double(scores[j]) - background(around: j, in: scores) }
        func flash(at f: Int) -> Bool {
            f >= 1 && f + 1 < scores.count
                && rise(f) >= limit && rise(f + 1) >= limit
                && Double(skips[f + 1]) - background(around: f, in: scores) < limit
        }
        return flash(at: i) || flash(at: i - 1)
    }

    /// Cuts found by applying a sensitivity to the saved change scores.
    /// A cut is a frame whose change rises over the change around it by at
    /// least the threshold, and is a local peak. Measuring the rise rather
    /// than the change itself means a steady change, a fade or a camera
    /// move, is never split, however strong it is, and a track never ends
    /// in a cut just because it ends while the picture is changing.
    /// The track is in the time of the file it was made from; with a
    /// `mapping` the cuts are returned in the original's time, and the
    /// sensitivity regions in `edits` (also original time) are read there.
    static func autoCuts(
        in track: ChangeScoreTrack, defaultSensitivity: Double, edits: SceneEdits = SceneEdits(),
        mapping: OriginalTimeMapping = .identity
    ) -> [CMTime] {
        guard track.frameCount > 2 else { return [] }
        let scores = track.scores
        let minimumGap = Int64((minimumSceneSeconds * Double(track.timescale)).rounded())

        var kept: [(index: Int, rise: Double)] = []
        for i in 1..<track.frameCount {
            let score = scores[i]
            let isPeak = score >= scores[i - 1] && (i + 1 == track.frameCount || score > scores[i + 1])
            guard isPeak else { continue }

            let time = track.time(at: i)
            let sensitivity = sensitivity(at: mapping.original(fromFile: time), defaultSensitivity: defaultSensitivity, edits: edits)
            let limit = threshold(forSensitivity: sensitivity) * 255
            let rise = Double(score) - background(around: i, in: scores)
            guard rise >= limit, !isFlash(i, in: track, limit: limit) else { continue }

            if let last = kept.last, track.times[i] - track.times[last.index] < minimumGap {
                if rise > last.rise { kept[kept.count - 1] = (i, rise) }
            } else {
                kept.append((i, rise))
            }
        }
        return kept.map { mapping.original(fromFile: track.time(at: $0.index)) }
    }

    /// Automatic cuts, minus the ones the person ignored, plus the ones they
    /// added, in time order.
    static func cuts(
        in track: ChangeScoreTrack?, defaultSensitivity: Double, edits: SceneEdits,
        mapping: OriginalTimeMapping = .identity
    ) -> [SceneCut] {
        var result: [SceneCut] = []
        if let track {
            for time in autoCuts(in: track, defaultSensitivity: defaultSensitivity, edits: edits, mapping: mapping)
            where !edits.ignoredCuts.contains(where: { CMTimeCompare($0, time) == 0 }) {
                result.append(SceneCut(time: time, origin: .auto))
            }
        }
        for time in edits.manualCuts where !result.contains(where: { CMTimeCompare($0.time, time) == 0 }) {
            result.append(SceneCut(time: time, origin: .manual))
        }
        return result.sorted { CMTimeCompare($0.time, $1.time) < 0 }
    }

    /// The scenes over each of `ranges` (in original time): cuts strictly
    /// inside a range split it; cuts at or outside its ends are discarded,
    /// never clamped into cuts at the ends.
    static func scenes(from cuts: [SceneCut], over ranges: [CMTimeRange]) -> [SceneRange] {
        ranges.flatMap { range in
            var scenes: [SceneRange] = []
            var start = range.start
            var origin = SceneCut.Origin.auto
            for cut in cuts where CMTimeCompare(cut.time, range.start) > 0 && CMTimeCompare(cut.time, range.end) < 0 {
                scenes.append(SceneRange(start: start, end: cut.time, origin: origin))
                start = cut.time
                origin = cut.origin
            }
            scenes.append(SceneRange(start: start, end: range.end, origin: origin))
            return scenes
        }
    }

    /// The scenes between cuts, covering the whole asset. Cuts at or beyond
    /// the ends are ignored. A scene is `manual` if the cut that starts it is.
    static func scenes(from cuts: [SceneCut], duration: CMTime) -> [SceneRange] {
        let inside = cuts.filter { CMTimeCompare($0.time, .zero) > 0 && CMTimeCompare($0.time, duration) < 0 }
        var scenes: [SceneRange] = []
        var start = CMTime.zero
        var origin = SceneCut.Origin.auto
        for cut in inside {
            scenes.append(SceneRange(start: start, end: cut.time, origin: origin))
            start = cut.time
            origin = cut.origin
        }
        scenes.append(SceneRange(start: start, end: duration, origin: origin))
        return scenes
    }
}
