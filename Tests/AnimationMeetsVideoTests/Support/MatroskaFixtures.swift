import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Matroska files made in the tests, with no footage or ffmpeg: H.264 with
/// reordered frames and AAC or FLAC sound are encoded by AVFoundation, read
/// back as they were written, and wrapped in Matroska by `EBMLWriter`.
///
/// The picture is black with one white frame at 1 s, and the sound silent
/// with a beep from 1 s, so a test can tell whether they still line up.
enum MatroskaFixture {
    static let width = 128, height = 72
    static let fps: Int32 = 25
    static let frames = 50
    static let sampleRate = 48_000.0
    static let flashFrame = 25

    enum Sound { case aac, flac }

    /// How the AAC encoder's priming is told. Matroska muxers do it either
    /// way: ffmpeg says it in CodecDelay; mkvmerge keeps the priming as
    /// sound at the start and starts the video that much later.
    enum Priming { case codecDelay, videoStartsLater }

    enum Lacing { case none, xiph, ebml }

    struct Options {
        var sound: Sound = .aac
        var priming: Priming = .codecDelay
        /// How sound packets are packed four to a block.
        var lacing: Lacing = .none
        var unknownSizeClusters = false
        /// Video frames in BlockGroups, with a ReferenceBlock on those that
        /// aren't keyframes, instead of SimpleBlocks.
        var blockGroups = false
    }

    /// What the Matroska file was made from: the frames and packets in the
    /// order they're stored, and the QuickTime movie they were read from.
    struct Source {
        var movie: URL
        var video: [Packet]
        var sound: [Packet]
        var avcC: Data
        var soundPrivate: Data
        /// The encoder's priming, in samples.
        var priming: Int64
    }

    struct Packet {
        var data: Data
        /// When it is shown, in seconds from the start of its track.
        var time: Double
        var isKey = true
    }

    /// Writes a Matroska file to `url` and returns what it was made from;
    /// the caller deletes `source.movie` and `url`.
    @discardableResult
    static func write(to url: URL, options: Options = Options()) async throws -> Source {
        let source = try await makeSource(sound: options.sound)
        try matroska(from: source, options: options).write(to: url)
        return source
    }

    // MARK: Encoding

    static func makeSource(sound: Sound) async throws -> Source {
        let movie = FileManager.default.temporaryDirectory.appending(path: "amv-mkv-source-\(UUID().uuidString).mov")
        await MovieWriterGate.shared.enter()
        let failure: String?
        do {
            failure = try await encodeWithRetries(to: movie)
        } catch {
            await MovieWriterGate.shared.leave()
            throw error
        }
        await MovieWriterGate.shared.leave()
        if let failure {
            Issue.record("Couldn't write the Matroska fixture's movie: \(failure)")
            throw CocoaError(.fileWriteUnknown)
        }
        let (video, avcC) = try await readVideo(movie)
        let (packets, soundPrivate, priming) = try await encodeSound(sound)
        return Source(movie: movie, video: video, sound: packets, avcC: avcC, soundPrivate: soundPrivate, priming: priming)
    }

    /// On CI's virtual Macs the H.264 encoder fails now and then when many
    /// tests write at once (see `writeMovie`), so a failed write is tried
    /// again; returns why the last try failed, or nil once written.
    private static func encodeWithRetries(to movie: URL) async throws -> String? {
        var failure: String?
        for attempt in 1...4 {
            try? FileManager.default.removeItem(at: movie)
            failure = try await encode(to: movie)
            if failure == nil { return nil }
            try? await Task.sleep(for: .milliseconds(100 * attempt))
        }
        return failure
    }

    /// The fixture's sound: silence, with a 1 kHz beep from 1 s.
    static func soundSamples() -> [Float] {
        let count = Int(Double(frames) / Double(fps) * sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            return time >= 1 && time < 1.1 ? Float(sin(2 * .pi * 1_000 * time) * 0.5) : 0
        }
    }

    /// The picture, alone in a movie: a writer with sound too waits to
    /// interleave it, and the reordering encoder holding frames back can
    /// leave both inputs waiting on each other.
    private static func encode(to url: URL) async throws -> String? {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: true,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 25,
            ],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(video)
        guard writer.startWriting() else { return writer.error?.localizedDescription ?? "couldn't start" }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frames {
            while !video.isReadyForMoreMediaData {
                if writer.status == .failed { return writer.error?.localizedDescription ?? "failed while writing" }
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            // Black, the flash white, with a gray bar that moves so every
            // frame differs and the encoder reorders some.
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            memset(base, index == flashFrame ? 255 : 0, row * height)
            if index != flashFrame {
                for y in 0..<8 { memset(base + y * row + (index * 2 % (width - 16)) * 4, 128, 64) }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
        }
        video.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? nil : (writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
    }

    /// The movie's frames as they were stored, in decode order, and the
    /// H.264 configuration.
    private static func readVideo(_ movie: URL) async throws -> ([Packet], avcC: Data) {
        let asset = AVURLAsset(url: movie)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
        let avcC = try #require((atoms as? [String: Any])?["avcC"] as? Data)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try #require(reader.startReading())
        var video: [Packet] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) > 0, CMSampleBufferGetDataBuffer(buffer) != nil else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            video.append(Packet(
                data: try bytes(of: buffer), time: CMSampleBufferGetPresentationTimeStamp(buffer).seconds, isKey: !notSync
            ))
        }
        try #require(reader.status == .completed, "\(String(describing: reader.error))")
        return (video, avcC)
    }

    /// The sound encoded by Core Audio and read back packet by packet,
    /// with what Matroska keeps as its private data and the encoder's
    /// priming in samples.
    private static func encodeSound(_ sound: Sound) async throws -> ([Packet], Data, priming: Int64) {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-mkv-\(UUID().uuidString).\(sound == .aac ? "m4a" : "flac")")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        do {
            let settings: [String: Any] = sound == .aac
                ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]
                : [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let samples = soundSamples()
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        var soundPrivate = Data()
        if sound == .aac {
            let description = try #require(try await track.load(.formatDescriptions).first)
            var size = 0
            let cookie = try #require(CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size))
            soundPrivate = audioSpecificConfig(fromESDS: Data(bytes: cookie, count: size))
        } else {
            // The file starts with "fLaC" and its metadata blocks, which are
            // what Matroska keeps as the track's private data.
            let bytes = [UInt8](try Data(contentsOf: url))
            var position = 4
            while position + 4 <= bytes.count {
                let isLast = bytes[position] & 0x80 != 0
                position += 4 + (Int(bytes[position + 1]) << 16 | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3]))
                if isLast { break }
            }
            soundPrivate = Data(bytes[0..<position])
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try #require(reader.startReading())
        var packets: [Packet] = []
        var time = 0.0
        var priming: Int64 = 0
        while let buffer = output.copyNextSampleBuffer() {
            if packets.isEmpty, sound == .aac,
               let trim = CMGetAttachment(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, attachmentModeOut: nil) as? NSDictionary {
                priming = Int64((CMTimeMakeFromDictionary(trim as CFDictionary).seconds * sampleRate).rounded())
            }
            for var packet in try Self.packets(of: buffer) {
                packet.time = time
                packets.append(packet)
                let length = sound == .aac ? 1_024 : FLACConfiguration.blockSize(of: packet.data[...]) ?? 0
                time += Double(length) / sampleRate
            }
        }
        try #require(reader.status == .completed, "\(String(describing: reader.error))")
        // Core Audio's AAC encoder primes by 2112 samples.
        if sound == .aac, priming == 0 { priming = 2_112 }
        return (packets, soundPrivate, priming)
    }

    private static func bytes(of buffer: CMSampleBuffer) throws -> Data {
        let block = try #require(CMSampleBufferGetDataBuffer(buffer))
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let status = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        try #require(status == kCMBlockBufferNoErr)
        return data
    }

    /// The compressed packets in a sound buffer, untimed: the caller
    /// times them one after another.
    private static func packets(of buffer: CMSampleBuffer) throws -> [Packet] {
        // The reader ends with a buffer that holds no sound.
        guard CMSampleBufferGetDataBuffer(buffer) != nil else { return [] }
        let data = try bytes(of: buffer)
        var pointer: UnsafePointer<AudioStreamPacketDescription>?
        var size = 0
        CMSampleBufferGetAudioStreamPacketDescriptionsPtr(buffer, packetDescriptionsPointerOut: &pointer, sizeOut: &size)
        let descriptions = pointer.map {
            Array(UnsafeBufferPointer(start: $0, count: size / MemoryLayout<AudioStreamPacketDescription>.size))
        } ?? []
        return descriptions.map { description in
            let start = Int(description.mStartOffset)
            return Packet(data: data.subdata(in: start..<(start + Int(description.mDataByteSize))), time: 0)
        }
    }

    /// The AudioSpecificConfig inside an ES descriptor magic cookie: the
    /// body of its DecoderSpecificInfo (tag 5).
    private static func audioSpecificConfig(fromESDS cookie: Data) -> Data {
        let bytes = [UInt8](cookie)
        var position = 0
        while position < bytes.count {
            let tag = bytes[position]
            position += 1
            var size = 0
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                size = size << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            switch tag {
            case 0x03: position += 3 // ES_ID and flags, then its children.
            case 0x04: position += 13 // Decoder config fields, then its children.
            case 0x05: return Data(bytes[position..<min(position + size, bytes.count)])
            default: position += size
            }
        }
        return Data()
    }

    // MARK: Muxing

    static func matroska(from source: Source, options: Options) -> Data {
        let primingSeconds = Double(source.priming) / sampleRate
        let videoOffset = options.priming == .videoStartsLater ? primingSeconds : 0
        let milliseconds = { (seconds: Double) in Int64((seconds * 1_000).rounded()) }

        var tracks = EBMLWriter.element(0xAE, [
            EBMLWriter.unsigned(0xD7, 1), EBMLWriter.unsigned(0x83, 1),
            EBMLWriter.string(0x86, "V_MPEG4/ISO/AVC"), EBMLWriter.element(0x63A2, source.avcC),
            EBMLWriter.unsigned(0x23E383, 40_000_000),
            EBMLWriter.element(0xE0, [EBMLWriter.unsigned(0xB0, UInt64(width)), EBMLWriter.unsigned(0xBA, UInt64(height))]),
        ])
        var soundEntry = [
            EBMLWriter.unsigned(0xD7, 2), EBMLWriter.unsigned(0x83, 2),
            EBMLWriter.string(0x86, options.sound == .aac ? "A_AAC" : "A_FLAC"),
            EBMLWriter.element(0x63A2, source.soundPrivate),
            EBMLWriter.element(0xE1, [EBMLWriter.float(0xB5, sampleRate), EBMLWriter.unsigned(0x9F, 1)]),
        ]
        if options.priming == .codecDelay, source.priming > 0 {
            soundEntry.append(EBMLWriter.unsigned(0x56AA, UInt64((primingSeconds * 1e9).rounded())))
        }
        tracks.append(EBMLWriter.element(0xAE, soundEntry))

        // Blocks in the order a muxer writes them: by time, the video in
        // decode order, four sound packets to a block when laced.
        struct Block { var order: Double; var time: Int64; var data: Data }
        var blocks: [Block] = []
        for (index, frame) in source.video.enumerated() {
            let time = milliseconds(frame.time + videoOffset)
            var header = Data([0x81]) // Track 1.
            let keyframe = frame.isKey
            if options.blockGroups {
                blocks.append(Block(order: Double(index) / Double(fps) + videoOffset, time: time, data: {
                    var block = header
                    block.append(contentsOf: [0, 0, 0])
                    block.append(frame.data)
                    var parts = [EBMLWriter.element(0xA1, block)]
                    if !keyframe { parts.append(EBMLWriter.signed(0xFB, -40)) }
                    return EBMLWriter.element(0xA0, parts)
                }()))
            } else {
                header.append(contentsOf: [0, 0, keyframe ? 0x80 : 0])
                header.append(frame.data)
                blocks.append(Block(order: Double(index) / Double(fps) + videoOffset, time: time, data: EBMLWriter.element(0xA3, header)))
            }
        }
        let perBlock = options.lacing == .none ? 1 : 4
        for start in stride(from: 0, to: source.sound.count, by: perBlock) {
            let packets = Array(source.sound[start..<min(start + perBlock, source.sound.count)])
            var block = Data([0x82, 0, 0, 0x80]) // Track 2, keyframe.
            if packets.count > 1 {
                block[3] |= options.lacing == .xiph ? 0x02 : 0x06
                block.append(UInt8(packets.count - 1))
                let sizes = packets.dropLast().map(\.data.count)
                switch options.lacing {
                case .xiph:
                    for size in sizes {
                        block.append(contentsOf: Array(repeating: 255, count: size / 255))
                        block.append(UInt8(size % 255))
                    }
                default:
                    block.append(EBMLWriter.size(sizes[0], length: 2))
                    for (previous, size) in zip(sizes, sizes.dropFirst()) {
                        // A signed difference, biased to an unsigned two-byte number.
                        block.append(EBMLWriter.size(size - previous + 8_191, length: 2))
                    }
                }
            }
            for packet in packets { block.append(packet.data) }
            blocks.append(Block(order: packets[0].time, time: milliseconds(packets[0].time), data: EBMLWriter.element(0xA3, block)))
        }
        blocks.sort { $0.order < $1.order }

        // Half a second to a cluster; a reordered frame can be shown before
        // its cluster's time, so its relative time is below zero.
        var clusters = Data()
        var index = 0
        while index < blocks.count {
            let clusterTime = max(blocks[index].time, 0)
            var body = EBMLWriter.unsigned(0xE7, UInt64(clusterTime))
            repeat {
                var data = blocks[index].data
                rewriteRelativeTime(in: &data, relative: Int16(blocks[index].time - clusterTime))
                body.append(data)
                index += 1
            } while index < blocks.count && blocks[index].time - clusterTime < 500
            clusters.append(options.unknownSizeClusters
                ? EBMLWriter.unknownSizeElement(0x1F43B675, body) : EBMLWriter.element(0x1F43B675, body))
        }

        let info = EBMLWriter.element(0x1549A966, [
            EBMLWriter.unsigned(0x2AD7B1, 1_000_000), EBMLWriter.float(0x4489, Double(frames) / Double(fps) * 1_000),
        ])
        var segment = info
        segment.append(EBMLWriter.element(0x1654AE6B, tracks))
        segment.append(clusters)
        var file = EBMLWriter.element(0x1A45DFA3, [EBMLWriter.string(0x4282, "matroska"), EBMLWriter.unsigned(0x4287, 4)])
        file.append(EBMLWriter.element(0x18538067, segment))
        return file
    }

    /// Sets the relative time in a SimpleBlock, or in a BlockGroup's
    /// Block, written with 0 there.
    private static func rewriteRelativeTime(in element: inout Data, relative: Int16) {
        // Both start with an ID and an 8-byte size; a group then holds its
        // Block, with its own ID and size, first.
        var position = element.startIndex
        if element[position] == 0xA0 { position += 1 + 8 }
        position += 1 + 8 + 1 // ID, size, track number.
        element[position] = UInt8(UInt16(bitPattern: relative) >> 8)
        element[position + 1] = UInt8(UInt16(bitPattern: relative) & 0xFF)
    }
}

/// Writes EBML elements, the building blocks of Matroska, with every size
/// in eight bytes so elements can be made before their parents.
enum EBMLWriter {
    static func id(_ id: UInt32) -> Data {
        let bytes = withUnsafeBytes(of: id.bigEndian) { Data($0) }
        return bytes.drop { $0 == 0 }
    }

    static func size(_ size: Int, length: Int = 8) -> Data {
        var data = Data(count: length)
        for index in 0..<length {
            data[index] = UInt8((size >> (8 * (length - 1 - index))) & 0xFF)
        }
        data[0] |= 0x80 >> (length - 1)
        return data
    }

    static func element(_ id: UInt32, _ body: Data) -> Data {
        var data = self.id(id)
        data.append(size(body.count))
        data.append(body)
        return data
    }

    static func element(_ id: UInt32, _ children: [Data]) -> Data {
        element(id, children.reduce(into: Data()) { $0.append($1) })
    }

    static func unknownSizeElement(_ id: UInt32, _ body: Data) -> Data {
        var data = self.id(id)
        data.append(contentsOf: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        data.append(body)
        return data
    }

    static func unsigned(_ id: UInt32, _ value: UInt64) -> Data {
        element(id, withUnsafeBytes(of: value.bigEndian) { Data($0) })
    }

    static func signed(_ id: UInt32, _ value: Int64) -> Data {
        element(id, withUnsafeBytes(of: value.bigEndian) { Data($0) })
    }

    static func float(_ id: UInt32, _ value: Double) -> Data {
        element(id, withUnsafeBytes(of: value.bitPattern.bigEndian) { Data($0) })
    }

    static func string(_ id: UInt32, _ value: String) -> Data {
        element(id, Data(value.utf8))
    }
}
