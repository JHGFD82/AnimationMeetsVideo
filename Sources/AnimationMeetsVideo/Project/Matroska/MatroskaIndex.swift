import Foundation

enum MatroskaError: LocalizedError {
    case notMatroska
    case malformed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notMatroska: "The file isn't a Matroska file."
        case .malformed(let detail): "The Matroska file can't be read: \(detail)."
        case .unsupported(let detail): "The Matroska file can't be used: \(detail)."
        }
    }
}

/// What a Matroska (MKV) file holds, read without decoding anything: its
/// tracks, and for each frame where its bytes sit in the file and when it
/// is shown. A reference movie built from it plays the file's frames from
/// where they are (see docs/matroska.md).
///
/// Only the headers of the file's elements are parsed, but since frame
/// headers sit all through the file, it is read straight through, in large
/// pieces (`MatroskaBytes`).
struct MatroskaIndex {
    enum TrackKind: Equatable {
        case video
        case audio
        case other
    }

    struct Track {
        var number: UInt64 = 0
        var kind: TrackKind = .other
        var codecID = ""
        var codecPrivate: Data?
        /// How long each frame lasts, in nanoseconds, when the file says.
        var defaultDuration: UInt64?
        /// Nanoseconds of decoded sound to drop from the start (Opus).
        var codecDelay: UInt64 = 0
        var pixelWidth = 0
        var pixelHeight = 0
        var sampleRate = 0.0
        var channels = 1
        var bitDepth = 0
        /// Compressed, encrypted or header-stripped frames: their bytes in
        /// the file aren't the codec's own, so they can't be referenced.
        var isEncoded = false
        /// In the order they are stored, which is decode order.
        var frames: [Frame] = []
    }

    struct Frame: Equatable {
        /// Where the frame's bytes start in the file, and how many there are.
        var offset: Int
        var size: Int
        /// When the frame is shown, in the file's timestamp units (see
        /// `timestampScale`). Frames laced into one block share its time.
        var time: Int64
        var isKey: Bool
        /// Its index within a laced block, 0 for a frame on its own.
        var laceIndex = 0
    }

    /// Nanoseconds per timestamp unit; 1,000,000 (milliseconds) unless the
    /// file says otherwise.
    var timestampScale: UInt64 = 1_000_000
    /// In timestamp units, when the file says.
    var duration: Double?
    var tracks: [Track] = []

    /// Reads the file at `url`, telling `progress` how far through it the
    /// read has got, 0...1. Cancelling the calling task stops the read.
    static func read(_ url: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> MatroskaIndex {
        let bytes = try MatroskaBytes(url: url)
        bytes.progress = progress
        var parser = Parser(bytes: bytes)
        return try parser.parse()
    }

    /// Reads the file's bytes, already in memory.
    static func read(_ data: Data) throws -> MatroskaIndex {
        var parser = Parser(bytes: MatroskaBytes(data: data))
        return try parser.parse()
    }
}

// MARK: - Element IDs

private enum ID {
    static let ebml: UInt32 = 0x1A45_DFA3
    static let docType: UInt32 = 0x4282
    static let segment: UInt32 = 0x1853_8067
    static let info: UInt32 = 0x1549_A966
    static let timestampScale: UInt32 = 0x2A_D7B1
    static let duration: UInt32 = 0x4489
    static let tracks: UInt32 = 0x1654_AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let defaultDuration: UInt32 = 0x23_E383
    static let codecDelay: UInt32 = 0x56AA
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let channels: UInt32 = 0x9F
    static let bitDepth: UInt32 = 0x6264
    static let contentEncodings: UInt32 = 0x6D80
    static let cluster: UInt32 = 0x1F43_B675
    static let timestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let referenceBlock: UInt32 = 0xFB

    /// The elements that sit directly in a segment, which end a cluster of
    /// unknown size.
    static let topLevel: Set<UInt32> = [
        cluster, info, tracks, 0x114D_9B74, 0x1C53_BB6B, 0x1254_C367, 0x1043_A770, 0x1941_A469, ebml,
    ]
}

// MARK: - Parser

private struct Parser {
    let bytes: MatroskaBytes
    var index = MatroskaIndex()

    init(bytes: MatroskaBytes) {
        self.bytes = bytes
    }

    struct Element {
        var id: UInt32
        /// Where its contents start, and where they end; nil when the file
        /// doesn't say (a live recording's segment or cluster).
        var start: Int
        var end: Int?
    }

    mutating func parse() throws -> MatroskaIndex {
        var position = 0
        guard let header = try element(at: position, limit: bytes.count), header.id == ID.ebml, let headerEnd = header.end else {
            throw MatroskaError.notMatroska
        }
        let docType = try children(of: header).first { $0.id == ID.docType }.map(string) ?? "matroska"
        guard docType == "matroska" || docType == "webm" else { throw MatroskaError.notMatroska }
        position = headerEnd

        while let segment = try element(at: position, limit: bytes.count) {
            guard segment.id == ID.segment else {
                position = try skip(segment)
                continue
            }
            try parseSegment(segment)
            break
        }
        guard !index.tracks.isEmpty else { throw MatroskaError.malformed("it has no tracks") }
        return index
    }

    private mutating func parseSegment(_ segment: Element) throws {
        let end = segment.end ?? bytes.count
        var position = segment.start
        while position < end, let child = try element(at: position, limit: end) {
            switch child.id {
            case ID.info: try parseInfo(child)
            case ID.tracks: try parseTracks(child)
            case ID.cluster:
                position = try parseCluster(child, segmentEnd: end)
                continue
            default: break
            }
            position = try skip(child)
        }
    }

    private mutating func parseInfo(_ info: Element) throws {
        for child in try children(of: info) {
            switch child.id {
            case ID.timestampScale: index.timestampScale = try unsigned(child)
            case ID.duration: index.duration = try float(child)
            default: break
            }
        }
    }

    private mutating func parseTracks(_ tracks: Element) throws {
        for entry in try children(of: tracks) where entry.id == ID.trackEntry {
            var track = MatroskaIndex.Track()
            for child in try children(of: entry) {
                switch child.id {
                case ID.trackNumber: track.number = try unsigned(child)
                case ID.trackType:
                    switch try unsigned(child) {
                    case 1: track.kind = .video
                    case 2: track.kind = .audio
                    default: track.kind = .other
                    }
                case ID.codecID: track.codecID = try string(child)
                case ID.codecPrivate: track.codecPrivate = try contents(child)
                case ID.defaultDuration: track.defaultDuration = try unsigned(child)
                case ID.codecDelay: track.codecDelay = try unsigned(child)
                case ID.contentEncodings: track.isEncoded = true
                case ID.video:
                    for field in try children(of: child) {
                        switch field.id {
                        case ID.pixelWidth: track.pixelWidth = Int(try unsigned(field))
                        case ID.pixelHeight: track.pixelHeight = Int(try unsigned(field))
                        default: break
                        }
                    }
                case ID.audio:
                    for field in try children(of: child) {
                        switch field.id {
                        case ID.samplingFrequency: track.sampleRate = try float(field)
                        case ID.channels: track.channels = Int(try unsigned(field))
                        case ID.bitDepth: track.bitDepth = Int(try unsigned(field))
                        default: break
                        }
                    }
                default: break
                }
            }
            index.tracks.append(track)
        }
    }

    /// Reads a cluster's frames, and returns where the next element starts.
    private mutating func parseCluster(_ cluster: Element, segmentEnd: Int) throws -> Int {
        let end = cluster.end ?? segmentEnd
        var clusterTime: Int64 = 0
        var position = cluster.start
        while position < end, let child = try element(at: position, limit: end) {
            // A cluster of unknown size ends where the next one starts.
            if cluster.end == nil, ID.topLevel.contains(child.id) { return position }
            switch child.id {
            case ID.timestamp: clusterTime = Int64(try unsigned(child))
            case ID.simpleBlock:
                try parseBlock(child, clusterTime: clusterTime, simple: true, hasReference: false)
            case ID.blockGroup:
                let parts = try children(of: child)
                let hasReference = parts.contains { $0.id == ID.referenceBlock }
                if let block = parts.first(where: { $0.id == ID.block }) {
                    try parseBlock(block, clusterTime: clusterTime, simple: false, hasReference: hasReference)
                }
            default: break
            }
            position = try skip(child)
        }
        return end
    }

    private mutating func parseBlock(_ block: Element, clusterTime: Int64, simple: Bool, hasReference: Bool) throws {
        guard let end = block.end else { throw MatroskaError.malformed("a block has no size") }
        var position = block.start
        guard let (trackNumber, numberLength) = try vint(at: position, keepMarker: false) else {
            throw MatroskaError.malformed("a block's track can't be read")
        }
        position += numberLength
        guard position + 3 <= end else { throw MatroskaError.malformed("a block is cut short") }
        let relative = Int16(bitPattern: UInt16(try bytes[position]) << 8 | UInt16(try bytes[position + 1]))
        let flags = try bytes[position + 2]
        position += 3
        guard let trackIndex = index.tracks.firstIndex(where: { $0.number == trackNumber }) else { return }

        let time = clusterTime + Int64(relative)
        let isKey = simple ? flags & 0x80 != 0 : !hasReference
        let sizes = try laceSizes(lacing: (flags >> 1) & 0x3, position: &position, end: end)
        for (laceIndex, size) in sizes.enumerated() {
            index.tracks[trackIndex].frames.append(
                .init(offset: position, size: size, time: time, isKey: isKey, laceIndex: laceIndex)
            )
            position += size
        }
        guard position == end else { throw MatroskaError.malformed("a block's frames don't fill it") }
    }

    /// The sizes of a block's frames, reading the lacing header after
    /// `position` and leaving `position` at the first frame.
    private func laceSizes(lacing: UInt8, position: inout Int, end: Int) throws -> [Int] {
        guard lacing != 0 else { return [end - position] }
        guard position < end else { throw MatroskaError.malformed("a laced block is cut short") }
        let count = Int(try bytes[position]) + 1
        position += 1
        guard count > 1 else { return [end - position] }
        var sizes: [Int] = []
        switch lacing {
        case 1: // Xiph: each size is a run of bytes added up, ending below 255.
            for _ in 0..<(count - 1) {
                var size = 0
                while true {
                    guard position < end else { throw MatroskaError.malformed("a laced block is cut short") }
                    let byte = Int(try bytes[position])
                    position += 1
                    size += byte
                    if byte < 255 { break }
                }
                sizes.append(size)
            }
        case 3: // EBML: the first size, then signed differences.
            guard let (first, length) = try vint(at: position, keepMarker: false) else {
                throw MatroskaError.malformed("a laced block's sizes can't be read")
            }
            position += length
            sizes.append(Int(first))
            for _ in 0..<(count - 2) {
                guard let (raw, length) = try vint(at: position, keepMarker: false) else {
                    throw MatroskaError.malformed("a laced block's sizes can't be read")
                }
                position += length
                let bias = (Int64(1) << (7 * length - 1)) - 1
                sizes.append(sizes[sizes.count - 1] + Int(Int64(raw) - bias))
            }
        default: // Fixed: equal sizes.
            let each = (end - position) / count
            return Array(repeating: each, count: count)
        }
        let used = sizes.reduce(0, +)
        sizes.append(end - position - used)
        guard sizes.allSatisfy({ $0 >= 0 }) else { throw MatroskaError.malformed("a laced block's sizes don't add up") }
        return sizes
    }

    // MARK: Elements

    /// The element starting at `position`, or nil at `limit`.
    private func element(at position: Int, limit: Int) throws -> Element? {
        guard position < limit else { return nil }
        guard let (id, idLength) = try vint(at: position, keepMarker: true), idLength <= 4,
              let (size, sizeLength) = try vint(at: position + idLength, keepMarker: false)
        else {
            throw MatroskaError.malformed("an element at byte \(position) can't be read")
        }
        let start = position + idLength + sizeLength
        let unknown = size == (UInt64(1) << (7 * UInt64(sizeLength))) - 1
        if unknown { return Element(id: UInt32(id), start: start, end: nil) }
        guard size <= UInt64(bytes.count - start) else {
            throw MatroskaError.malformed("an element at byte \(position) runs past the end")
        }
        return Element(id: UInt32(id), start: start, end: start + Int(size))
    }

    private func skip(_ element: Element) throws -> Int {
        guard let end = element.end else { throw MatroskaError.malformed("an element of unknown size can't be skipped") }
        return end
    }

    private func children(of element: Element) throws -> [Element] {
        guard let end = element.end else { throw MatroskaError.malformed("an element of unknown size") }
        var found: [Element] = []
        var position = element.start
        while let child = try self.element(at: position, limit: end) {
            found.append(child)
            position = try skip(child)
        }
        return found
    }

    /// An EBML variable-length integer: its length is told by its first
    /// set bit. IDs keep that bit; sizes and values drop it.
    private func vint(at position: Int, keepMarker: Bool) throws -> (UInt64, Int)? {
        guard position < bytes.count else { return nil }
        let first = try bytes[position]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard position + length <= bytes.count else { return nil }
        var value = UInt64(keepMarker ? first : first & (0xFF >> length))
        for offset in 1..<length {
            value = value << 8 | UInt64(try bytes[position + offset])
        }
        return (value, length)
    }

    private func contents(_ element: Element) throws -> Data {
        guard let end = element.end else { throw MatroskaError.malformed("an element of unknown size") }
        return try bytes.data(in: element.start..<end)
    }

    private func unsigned(_ element: Element) throws -> UInt64 {
        guard let end = element.end, end - element.start <= 8 else { throw MatroskaError.malformed("a number is too long") }
        return try bytes.data(in: element.start..<end).reduce(0) { $0 << 8 | UInt64($1) }
    }

    private func float(_ element: Element) throws -> Double {
        let raw = try unsigned(element)
        switch element.end.map({ $0 - element.start }) {
        case 4: return Double(Float(bitPattern: UInt32(raw)))
        case 8: return Double(bitPattern: raw)
        case 0: return 0
        default: throw MatroskaError.malformed("a number has an odd length")
        }
    }

    private func string(_ element: Element) throws -> String {
        let data = try contents(element)
        let trimmed = data.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }
}
