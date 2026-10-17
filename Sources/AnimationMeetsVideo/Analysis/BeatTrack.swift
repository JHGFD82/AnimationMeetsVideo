import CoreMedia
import Foundation

/// The beats found in one asset's audio, in the asset's own time. This is
/// what beat detection saves; where the beats land on the timeline is worked
/// out from the clip's placement, so moving or trimming a clip needs no
/// re-detection.
///
/// The initializer checks every invariant and the properties can't be
/// changed afterwards, so a track in hand is always one the searches and
/// tempo arithmetic below can rely on.
struct BeatTrack: Equatable, Sendable {
    /// Units per second for `times`; positive.
    let timescale: Int32
    /// Beat positions in `timescale` units, strictly increasing.
    let times: [Int64]
    /// The typical tempo, from the median gap between the beats; 0 exactly
    /// when no beat was found, otherwise positive. Finite, and stays so when saved as a 32-bit float.
    let beatsPerMinute: Double

    var isEmpty: Bool { times.isEmpty }

    /// Throws `BeatTrackError.invalidData` unless the values meet the
    /// invariants documented on the properties.
    init(timescale: Int32, times: [Int64], beatsPerMinute: Double) throws {
        guard timescale > 0 else { throw BeatTrackError.invalidData("the timescale isn't positive") }
        guard times.count <= Int(UInt32.max) else { throw BeatTrackError.invalidData("there are too many beats") }
        guard zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw BeatTrackError.invalidData("the beat times don't strictly increase")
        }
        let saved = Float(beatsPerMinute)
        guard beatsPerMinute.isFinite, saved.isFinite, beatsPerMinute >= 0 else {
            throw BeatTrackError.invalidData("the tempo isn't a finite, nonnegative number")
        }
        guard times.isEmpty ? beatsPerMinute == 0 : saved > 0 else {
            throw BeatTrackError.invalidData("the tempo doesn't match whether there are beats")
        }
        self.timescale = timescale
        self.times = times
        self.beatsPerMinute = beatsPerMinute
    }

    /// The slowest and fastest tempo the beats keep up for a few beats,
    /// leaving out the slowest and fastest tenth so one odd gap doesn't
    /// count. Nil with too few beats to tell.
    var tempoRange: ClosedRange<Double>? {
        guard times.count >= 6 else { return nil }
        let gaps = zip(times.dropFirst(), times).map { Self.distance(from: $1, to: $0) / Double(timescale) }
        let steady = (0...(gaps.count - 4)).map { index -> Double in
            gaps[index..<(index + 4)].sorted()[1...2].reduce(0, +) / 2
        }
        let tempos = steady.filter { $0 > 0 }.map { 60 / $0 }.filter(\.isFinite).sorted()
        guard !tempos.isEmpty else { return nil }
        let low = tempos[tempos.count / 10], high = tempos[tempos.count - 1 - tempos.count / 10]
        return low...high
    }

    /// `end - start` as a Double, exact where it fits in an Int64 and close
    /// where the subtraction would overflow.
    private static func distance(from start: Int64, to end: Int64) -> Double {
        let (difference, overflow) = end.subtractingReportingOverflow(start)
        return overflow ? Double(end) - Double(start) : Double(difference)
    }

    /// Nothing was found. Saved like any other result so the audio is not
    /// analyzed again every time the project opens.
    static func none(timescale: Int32 = 1000) -> BeatTrack {
        // A positive timescale is the only invariant an empty track can break.
        try! BeatTrack(timescale: max(timescale, 1), times: [], beatsPerMinute: 0)
    }

    /// Beats from `start` up to but not including `end`, in asset time.
    /// Empty when either time isn't a number or the range is reversed.
    func beats(from start: CMTime, to end: CMTime) -> [CMTime] {
        indices(from: start, to: end).map { CMTime(value: times[$0], timescale: timescale) }
    }

    /// Whether any beat lies in `start..<end`, by binary search, without
    /// building the list `beats(from:to:)` returns.
    func hasBeats(from start: CMTime, to end: CMTime) -> Bool {
        !indices(from: start, to: end).isEmpty
    }

    /// The indices of the beats in `start..<end`. The bounds are compared
    /// exactly rather than converted to `timescale`, which would round a
    /// bound that falls between two ticks onto one of them and so let in a
    /// beat just before `start` or leave out one just before `end`.
    private func indices(from start: CMTime, to end: CMTime) -> Range<Int> {
        guard Self.isUsable(start), Self.isUsable(end), CMTimeCompare(start, end) < 0 else { return 0..<0 }
        let first = firstIndex(atOrAfter: start)
        let last = firstIndex(atOrAfter: end)
        return first < last ? first..<last : 0..<0
    }

    private static func isUsable(_ time: CMTime) -> Bool {
        time.isNumeric && time.timescale > 0
    }

    private func firstIndex(atOrAfter time: CMTime) -> Int {
        times.lowerBound(of: time) { CMTime(value: $0, timescale: timescale) }
    }

    // MARK: Serialization

    private static let magic: [UInt8] = Array("AMVB".utf8)
    /// 2 since the tempo may change; files of version 1 hold beats fitted to
    /// one steady tempo, so they are read as missing and detected again.
    private static let version: UInt32 = 2

    /// Compact binary form: a header, then every beat time. All integers are
    /// little endian; the tempo is a 32-bit float's bit pattern. The
    /// initializer guarantees the count fits its field.
    func encoded() -> Data {
        var data = Data(Self.magic)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(Self.version)
        append(timescale)
        append(UInt32(times.count))
        append(Float(beatsPerMinute).bitPattern)
        for time in times { append(time) }
        return data
    }

    /// Throws `BeatTrackError` when the data isn't a beat file of this
    /// version, is cut short or too long, or holds values that break the
    /// track's invariants (`invalidData`).
    init(decoding data: Data) throws {
        var offset = 0
        func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard data.count - offset >= size else { throw BeatTrackError.truncated }
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: (data.startIndex + offset)..<(data.startIndex + offset + size)) }
            offset += size
            return T(littleEndian: value)
        }

        guard data.count >= Self.magic.count, Array(data.prefix(Self.magic.count)) == Self.magic else {
            throw BeatTrackError.notABeatFile
        }
        offset = Self.magic.count
        let version = try read(UInt32.self)
        guard version == Self.version else { throw BeatTrackError.unsupportedVersion(version) }
        let timescale = try read(Int32.self)
        let count = Int(try read(UInt32.self))
        let tempo = Float(bitPattern: try read(UInt32.self))
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<Int64>.size)
        guard !overflow, data.count - offset == byteCount else { throw BeatTrackError.truncated }

        var times: [Int64] = []
        times.reserveCapacity(count)
        for _ in 0..<count { times.append(try read(Int64.self)) }
        try self.init(timescale: timescale, times: times, beatsPerMinute: Double(tempo))
    }
}

extension RandomAccessCollection {
    /// The index of the first element whose key is at or after `value`, or
    /// `endIndex` if none is, in a collection sorted by `key`.
    func lowerBound<Key: Comparable>(of value: Key, by key: (Element) -> Key) -> Index {
        var low = startIndex
        var count = self.count
        while count > 0 {
            let half = count / 2
            let middle = index(low, offsetBy: half)
            if key(self[middle]) < value {
                low = index(after: middle)
                count -= half + 1
            } else {
                count = half
            }
        }
        return low
    }
}

enum BeatTrackError: LocalizedError, Equatable {
    case notABeatFile
    case unsupportedVersion(UInt32)
    case truncated
    /// The values break one of `BeatTrack`'s invariants; says which.
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .notABeatFile: "This isn't a beat data file."
        case .unsupportedVersion(let version): "Beat data version \(version) isn't supported."
        case .truncated: "The beat data file is damaged."
        case .invalidData(let reason): "The beat data is invalid: \(reason)."
        }
    }
}
