import CoreMedia
import CryptoKit
import Foundation

/// What a media file looked like when it was imported. Saved in the project
/// so that after the file is replaced the app can still compare the new file
/// with the original, which is no longer there to read.
struct AssetMetadataSnapshot: Codable, Equatable, Sendable {
    var fileName: String
    var originalPath: String
    var byteCount: Int64
    /// Seconds since 1970 of the file's last change. Together with the size
    /// this tells whether the file was swapped after the snapshot.
    var modified: Double?
    var isVideo: Bool
    var durationValue: Int64
    var durationTimescale: Int32
    var frameRate: Double
    /// Displayed size, after any rotation. Zero for audio.
    var width: Int
    var height: Int
    var codecName: String
    /// Color tags as the file declares them; nil when untagged.
    var colorPrimaries: String?
    var colorTransfer: String?
    var colorMatrix: String?
    var audioSampleRate: Double?
    var capturedAt: Double

    var duration: CMTime { CMTime(value: durationValue, timescale: durationTimescale) }
    var hasAudio: Bool { audioSampleRate != nil }
    var hasColorTags: Bool { colorPrimaries != nil && colorTransfer != nil && colorMatrix != nil }

    /// Whether `url` still holds the file this snapshot describes, judged by
    /// size and modification time. False when it's gone or was swapped.
    func describes(fileAt url: URL) -> Bool {
        guard let stamp = FileStamp(url: url) else { return false }
        return stamp.byteCount == byteCount && stamp.modified == modified
    }
}

/// Size and modification time of a file on disk.
struct FileStamp: Codable, Equatable, Sendable {
    var byteCount: Int64
    var modified: Double?

    init?(url: URL) {
        // URL objects cache resource values, which would hide a swapped file.
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize
        else {
            return nil
        }
        byteCount = Int64(size)
        modified = values.contentModificationDate?.timeIntervalSince1970
    }

    /// A name for something made from the file at `url`: a hash of its
    /// path, size and modification date, so a file moved or changed gets a
    /// new one. Nil when the file can't be looked at.
    static func cacheDigest(for url: URL) -> String? {
        // A URL keeps what it last read of its file; a file replaced since
        // must be looked at afresh.
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate
        else { return nil }
        let key = "\(url.standardizedFileURL.path)|\(size)|\(date.timeIntervalSinceReferenceDate)"
        return SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// How loud a file is over time, 100 values a second. Two versions of the
/// same recording have the same envelope, so it's what finds the offset
/// between them.
struct AudioEnvelope: Equatable, Sendable {
    static let windowsPerSecond = 100
    /// Quietest level that isn't treated as silence, in dBFS.
    static let floorDecibels = -80.0

    /// Index of the window `levels[0]` describes (normally 0).
    var startWindow: Int64
    /// 0 is silence (at or under `floorDecibels`), 255 is full scale.
    var levels: [UInt8]

    static func level(forRMS rms: Double) -> UInt8 {
        guard rms > 0 else { return 0 }
        let decibels = max(20 * log10(rms), floorDecibels)
        return UInt8(((decibels - floorDecibels) / -floorDecibels * 255).rounded())
    }

    var duration: Double { Double(levels.count) / Double(Self.windowsPerSecond) }

    private static let magic: [UInt8] = Array("AMVE".utf8)
    private static let version: UInt32 = 1

    func encoded() -> Data {
        var data = Data(Self.magic)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(Self.version)
        append(UInt32(Self.windowsPerSecond))
        append(startWindow)
        append(UInt32(levels.count))
        data.append(contentsOf: levels)
        return data
    }

    init(startWindow: Int64, levels: [UInt8]) {
        self.startWindow = startWindow
        self.levels = levels
    }

    init(decoding data: Data) throws {
        var offset = 0
        func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw AudioEnvelopeError.truncated }
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: (data.startIndex + offset)..<(data.startIndex + offset + size)) }
            offset += size
            return T(littleEndian: value)
        }

        guard data.count >= Self.magic.count, Array(data.prefix(Self.magic.count)) == Self.magic else {
            throw AudioEnvelopeError.notAnEnvelopeFile
        }
        offset = Self.magic.count
        let version = try read(UInt32.self)
        guard version == Self.version else { throw AudioEnvelopeError.unsupportedVersion(version) }
        let rate = try read(UInt32.self)
        guard rate == UInt32(Self.windowsPerSecond) else { throw AudioEnvelopeError.unsupportedVersion(version) }
        let start = try read(Int64.self)
        let count = Int(try read(UInt32.self))
        guard data.count - offset == count else { throw AudioEnvelopeError.truncated }
        self.init(startWindow: start, levels: [UInt8](data[(data.startIndex + offset)...]))
    }
}

enum AudioEnvelopeError: LocalizedError {
    case notAnEnvelopeFile
    case unsupportedVersion(UInt32)
    case truncated

    var errorDescription: String? {
        switch self {
        case .notAnEnvelopeFile: "This isn't an audio envelope file."
        case .unsupportedVersion(let version): "Audio envelope version \(version) isn't supported."
        case .truncated: "The audio envelope file is damaged."
        }
    }
}

/// Everything saved about an asset's original file at import.
struct AssetReference: Equatable, Sendable {
    var metadata: AssetMetadataSnapshot
    /// Nil when the file has no audio.
    var audioEnvelope: AudioEnvelope?
}
