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

    var frameCount: Int { times.count }

    func time(at index: Int) -> CMTime {
        CMTime(value: times[index], timescale: timescale)
    }

    // MARK: Serialization

    private static let magic: [UInt8] = Array("AMVS".utf8)
    private static let version: UInt32 = 1

    /// Compact binary form: a header, then every frame time, then the scores
    /// (one byte per frame). All integers are little endian.
    func encoded() -> Data {
        var data = Data(Self.magic)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(Self.version)
        append(timescale)
        append(UInt32(times.count))
        for time in times { append(time) }
        data.append(contentsOf: scores)
        return data
    }

    init(timescale: Int32, times: [Int64], scores: [UInt8]) {
        precondition(times.count == scores.count, "one score per frame")
        self.timescale = timescale
        self.times = times
        self.scores = scores
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
        guard version == Self.version else { throw ChangeScoreTrackError.unsupportedVersion(version) }
        let timescale = try read(Int32.self)
        let count = Int(try read(UInt32.self))
        guard timescale > 0, data.count - offset == count * 9 else { throw ChangeScoreTrackError.truncated }

        var times: [Int64] = []
        times.reserveCapacity(count)
        for _ in 0..<count { times.append(try read(Int64.self)) }
        let scores = [UInt8](data[(data.startIndex + offset)...])
        self.init(timescale: timescale, times: times, scores: scores)
        try validate()
    }

    /// Checks the track against its documented format, so nothing downstream
    /// has to cope with a malformed one:
    /// - `timescale` is positive;
    /// - frame times are not negative and strictly increase (a frame whose
    ///   time repeats or goes back is an error, not something to sort away);
    /// - the first frame has no previous frame, so its score is 0.
    /// Every score value, 0 to 255, is valid. An empty track is valid.
    func validate() throws {
        guard timescale > 0 else { throw ChangeScoreTrackError.invalid("The time scale isn't positive.") }
        guard times.count == scores.count else { throw ChangeScoreTrackError.invalid("Frames and scores don't match.") }
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
        let s = min(max(sensitivity, 0), 1)
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

    /// Cuts found by applying a sensitivity to the saved change scores.
    /// A cut is a frame whose change is over the threshold and is a local
    /// peak, so a slow dissolve or a camera move isn't split in the middle.
    static func autoCuts(in track: ChangeScoreTrack, defaultSensitivity: Double, edits: SceneEdits = SceneEdits()) -> [CMTime] {
        guard track.frameCount > 2 else { return [] }
        let scores = track.scores
        let minimumGap = Int64((minimumSceneSeconds * Double(track.timescale)).rounded())

        var kept: [(index: Int, score: UInt8)] = []
        for i in 1..<track.frameCount {
            let score = scores[i]
            let isPeak = score >= scores[i - 1] && (i + 1 == track.frameCount || score > scores[i + 1])
            guard isPeak else { continue }

            let time = track.time(at: i)
            let sensitivity = sensitivity(at: time, defaultSensitivity: defaultSensitivity, edits: edits)
            guard Double(score) / 255 >= threshold(forSensitivity: sensitivity) else { continue }

            if let last = kept.last, track.times[i] - track.times[last.index] < minimumGap {
                if score > last.score { kept[kept.count - 1] = (i, score) }
            } else {
                kept.append((i, score))
            }
        }
        return kept.map { track.time(at: $0.index) }
    }

    /// Automatic cuts, minus the ones the person ignored, plus the ones they
    /// added, in time order.
    static func cuts(in track: ChangeScoreTrack?, defaultSensitivity: Double, edits: SceneEdits) -> [SceneCut] {
        var result: [SceneCut] = []
        if let track {
            for time in autoCuts(in: track, defaultSensitivity: defaultSensitivity, edits: edits)
            where !edits.ignoredCuts.contains(where: { CMTimeCompare($0, time) == 0 }) {
                result.append(SceneCut(time: time, origin: .auto))
            }
        }
        for time in edits.manualCuts where !result.contains(where: { CMTimeCompare($0.time, time) == 0 }) {
            result.append(SceneCut(time: time, origin: .manual))
        }
        return result.sorted { CMTimeCompare($0.time, $1.time) < 0 }
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
