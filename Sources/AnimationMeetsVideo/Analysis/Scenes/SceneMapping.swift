import CoreMedia
import Foundation

/// Time in the original footage and time in the file an asset uses now.
/// Trims, scenes, cuts, hand edits and sensitivity regions are all in the
/// original's time; scores, and the frames a file really has, are in the
/// file's. The whole app converts between them here, so the sign is written
/// once:
///
///     offset = fileTime − originalTime   (`MediaClip.alignmentOffset`)
///     originalTime = fileTime − offset
///     fileTime     = originalTime + offset
struct OriginalTimeMapping: Equatable, Sendable {
    var offset: CMTime

    static let identity = OriginalTimeMapping(offset: .zero)

    func original(fromFile time: CMTime) -> CMTime { CMTimeSubtract(time, offset) }
    func file(fromOriginal time: CMTime) -> CMTime { CMTimeAdd(time, offset) }

    func original(fromFile range: CMTimeRange) -> CMTimeRange {
        CMTimeRange(start: original(fromFile: range.start), end: original(fromFile: range.end))
    }
}

extension MediaClip {
    var timeMapping: OriginalTimeMapping { OriginalTimeMapping(offset: alignmentOffset) }

    /// The original's editing-time domain: from 0 to the original file's
    /// length. Nil end when it isn't known (an asset replaced before the
    /// original's length was kept), in which case the replacement's own end
    /// is the only limit. A replacement never extends this domain.
    var originalDomainEnd: CMTime? {
        originalDuration ?? (wasReplaced ? nil : duration)
    }
}

/// Which stretches of the original's time can be played from the file the
/// asset uses now, and which cannot.
struct SceneCoverage: Equatable, Sendable {
    /// Scenes over the usable stretches, in original time.
    var scenes: [SceneRange]
    /// Stretches of original time that both the original's domain and the
    /// replacement's footage cover, ascending and apart.
    var usable: [CMTimeRange]
    /// Stretches of the original's domain the replacement has no footage
    /// for. Nothing is made up for them: no scene, no frozen frame.
    var uncovered: [CMTimeRange]

    /// The replacement and the original's time don't overlap at all.
    var hasNoOverlap: Bool { usable.isEmpty }

    var isComplete: Bool { uncovered.isEmpty && !usable.isEmpty }

    /// Stretches with no footage between two stretches that have some: empty
    /// edits inside the file, as opposed to the footage simply starting
    /// late or ending early, which `uncovered` also lists.
    var internalGaps: [CMTimeRange] {
        zip(usable, usable.dropFirst()).map { CMTimeRange(start: $0.end, end: $1.start) }
    }

    /// The scenes cut down to `trim`, in original time, for work on a clip
    /// that uses only part of the asset. A scene partly inside is cut at the
    /// trim; one wholly outside is left out.
    func scenes(within trim: CMTimeRange) -> [SceneRange] {
        scenes.compactMap { scene in
            let start = CMTimeMaximum(scene.start, trim.start), end = CMTimeMinimum(scene.end, trim.end)
            return CMTimeCompare(start, end) < 0 ? SceneRange(start: start, end: end, origin: scene.origin) : nil
        }
    }
}

enum SceneDomain {
    /// `[0, duration)` of a file with `emptySpans` (in `timescale` units)
    /// taken out, ascending, in the file's time.
    static func footage(duration: CMTime, emptySpans: [ChangeScoreTrack.EmptySpan], timescale: Int32) -> [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        var cursor = CMTime.zero
        for span in emptySpans {
            let start = CMTime(value: span.start, timescale: timescale), end = CMTime(value: span.end, timescale: timescale)
            if CMTimeCompare(cursor, start) < 0 { ranges.append(CMTimeRange(start: cursor, end: CMTimeMinimum(start, duration))) }
            cursor = CMTimeMaximum(cursor, end)
        }
        if CMTimeCompare(cursor, duration) < 0 { ranges.append(CMTimeRange(start: cursor, end: duration)) }
        return ranges.filter { CMTimeCompare($0.start, $0.end) < 0 }
    }

    /// `[a.start, a.end) ∩ [b.start, b.end)`, or nil when empty. `b.end` nil
    /// means unbounded.
    static func intersection(_ a: CMTimeRange, start: CMTime, end: CMTime?) -> CMTimeRange? {
        let lower = CMTimeMaximum(a.start, start)
        let upper = end.map { CMTimeMinimum(a.end, $0) } ?? a.end
        return CMTimeCompare(lower, upper) < 0 ? CMTimeRange(start: lower, end: upper) : nil
    }

    /// What of `[0, end)` (or `[0, ∞)` when `end` is nil, in which case only
    /// the part before the first usable range is reported) the usable
    /// ranges leave out.
    static func uncovered(domainEnd end: CMTime?, usable: [CMTimeRange]) -> [CMTimeRange] {
        var gaps: [CMTimeRange] = []
        var cursor = CMTime.zero
        for range in usable {
            if CMTimeCompare(cursor, range.start) < 0 { gaps.append(CMTimeRange(start: cursor, end: range.start)) }
            cursor = CMTimeMaximum(cursor, range.end)
        }
        if let end, CMTimeCompare(cursor, end) < 0 { gaps.append(CMTimeRange(start: cursor, end: end)) }
        return gaps
    }
}
