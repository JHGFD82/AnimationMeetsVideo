import AVFoundation
import CoreMedia
import Foundation

/// A QuickTime movie whose samples are the frames of a Matroska file,
/// referenced where they sit in it rather than copied: the movie holds
/// only the index, so AVFoundation can play, read and compose the file's
/// H.264, HEVC, AAC, FLAC and PCM tracks for a few megabytes of disk (see
/// docs/matroska.md).
///
/// Each frame becomes a sample buffer that carries no data, only the
/// file's URL and the frame's byte offset; a movie track appending one
/// adds a reference to those bytes instead of writing them.
enum MatroskaReferenceMovie {
    /// Writes the movie for the Matroska file at `source` to `destination`,
    /// with its first video track and first audio track that can be used.
    /// Throws when neither can.
    static func write(index: MatroskaIndex, source: URL, to destination: URL) throws {
        guard index.tracks.contains(where: isUsable) else {
            throw MatroskaError.unsupported("it has no H.264, HEVC, AAC, FLAC or PCM track")
        }
        let bytes = try Data(contentsOf: source, options: .alwaysMapped)
        let plans = try usableTracks(in: index, bytes: bytes)
        let start = plans.map(\.start).min() ?? .zero

        let movie = AVMutableMovie()
        // Fine enough for the video's frames, and for where the sound starts
        // against them.
        movie.timescale = max(plans.first { $0.kind == .video }?.timescale ?? 600, 600)
        for plan in plans {
            try append(plan, to: movie, source: source, start: start)
        }
        try? FileManager.default.removeItem(at: destination)
        try movie.writeHeader(to: destination, fileType: .mov, options: .truncateDestinationToMovieHeaderOnly)
    }

    // MARK: Planning

    /// One track as it goes into the movie: its samples in decode order,
    /// timed in the track's own timescale.
    struct TrackPlan {
        var kind: MatroskaIndex.TrackKind
        var format: CMFormatDescription
        var timescale: CMTimeScale
        var samples: [Sample]
        /// When its first sample is shown.
        var start: CMTime
        /// How much decoded sound at the start isn't part of it (the
        /// encoder's priming), in the track's timescale.
        var priming: Int64 = 0

        struct Sample {
            var offset: Int
            var size: Int
            /// How many samples the bytes hold: 1 for a frame or packet,
            /// the frame count for PCM.
            var count = 1
            var decodeTime: Int64
            var presentationTime: Int64
            var duration: Int64
            var isKey: Bool
        }
    }

    /// The tracks that can go into the movie. `bytes` is the file, for the
    /// codecs whose frame headers say how long a frame lasts.
    static func usableTracks(in index: MatroskaIndex, bytes: Data) throws -> [TrackPlan] {
        var plans: [TrackPlan] = []
        if let video = index.tracks.first(where: { $0.kind == .video && isUsable($0) }) {
            plans.append(try videoPlan(video, scale: index.timestampScale))
        }
        if let audio = index.tracks.first(where: { $0.kind == .audio && isUsable($0) }) {
            plans.append(try audioPlan(audio, scale: index.timestampScale, bytes: bytes))
        }
        return plans
    }

    /// Whether the track's frames can be referenced as they are and decoded.
    static func isUsable(_ track: MatroskaIndex.Track) -> Bool {
        guard !track.isEncoded else { return false }
        switch track.kind {
        case .video: return videoCodec(track) != nil
        case .audio: return audioCodec(track) != nil
        case .other: return false
        }
    }

    private static func videoCodec(_ track: MatroskaIndex.Track) -> (CMVideoCodecType, String)? {
        switch track.codecID {
        case "V_MPEG4/ISO/AVC": (kCMVideoCodecType_H264, "avcC")
        case "V_MPEGH/ISO/HEVC": (kCMVideoCodecType_HEVC, "hvcC")
        default: nil
        }
    }

    private static func audioCodec(_ track: MatroskaIndex.Track) -> AudioFormatID? {
        switch track.codecID {
        case "A_AAC", "A_AAC/MPEG4/LC", "A_AAC/MPEG2/LC": kAudioFormatMPEG4AAC
        case "A_FLAC": kAudioFormatFLAC
        case "A_PCM/INT/LIT": kAudioFormatLinearPCM
        default: nil
        }
    }

    // MARK: Video

    private static func videoPlan(_ track: MatroskaIndex.Track, scale: UInt64) throws -> TrackPlan {
        guard let (codec, atom) = videoCodec(track), let configuration = track.codecPrivate else {
            throw MatroskaError.unsupported("its video has no decoder configuration")
        }
        var format: CMVideoFormatDescription?
        let extensions = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: configuration],
        ] as CFDictionary
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: codec, width: Int32(track.pixelWidth), height: Int32(track.pixelHeight),
            extensions: extensions, formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw MatroskaError.unsupported("its video's configuration can't be read") }

        let timing = VideoTiming(track: track, scale: scale, origin: track.frames.map(\.time).min() ?? 0)
        let times = track.frames.map { timing.value(for: $0.time) }
        // Matroska stores only when frames are shown. Frames are stored in
        // decode order, so the n-th decode time is the n-th earliest show
        // time, moved back by the most any frame was reordered so no frame
        // is decoded after it is shown.
        let sorted = times.sorted()
        let delay = zip(sorted, times).map { $0 - $1 }.max() ?? 0
        let decodeTimes = sorted.map { $0 - delay }
        let lastDuration = timing.frameDuration ?? (sorted.count > 1 ? sorted[sorted.count - 1] - sorted[sorted.count - 2] : 1)

        var samples: [TrackPlan.Sample] = []
        samples.reserveCapacity(track.frames.count)
        for (position, frame) in track.frames.enumerated() {
            let next = position + 1 < decodeTimes.count ? decodeTimes[position + 1] : decodeTimes[position] + lastDuration
            samples.append(.init(
                offset: frame.offset, size: frame.size,
                decodeTime: decodeTimes[position], presentationTime: times[position],
                duration: max(next - decodeTimes[position], 1), isKey: frame.isKey
            ))
        }
        let start = CMTime(value: sorted.first ?? 0, timescale: timing.timescale)
        return TrackPlan(kind: .video, format: format, timescale: timing.timescale, samples: samples, start: start)
    }

    /// Video times in a timescale fine enough for the frame rate. Matroska
    /// keeps times in milliseconds, which can't say 1/29.97 of a second;
    /// when the track's frame duration is a common rate's, times are
    /// snapped to that rate's frames, counted from the first frame so a
    /// track that starts between frames (to line up with its sound) keeps
    /// its start. The timescale is the rate's times 1000, which can say
    /// both the frames and that start to the millisecond.
    struct VideoTiming {
        var timescale: CMTimeScale
        /// One frame in `timescale`, when the rate is a common one.
        var frameDuration: Int64?
        private var nanosecondsPerUnit: Double
        private var frameNanoseconds: Double?
        private var originNanoseconds: Double

        static let commonRates: [(timescale: CMTimeScale, frame: Int64)] = [
            (24000, 1001), (24, 1), (25, 1), (30000, 1001), (30, 1), (50, 1), (60000, 1001), (60, 1),
            (48, 1), (100, 1), (120000, 1001), (120, 1),
        ]

        /// `origin` is the first frame's time, in the file's units.
        init(track: MatroskaIndex.Track, scale: UInt64, origin: Int64) {
            nanosecondsPerUnit = Double(scale)
            originNanoseconds = Double(origin) * Double(scale)
            // Files keep the frame duration in whole nanoseconds, so a
            // common rate's is off by under one; 30 and 29.97 are 0.1% apart.
            if let nanoseconds = track.defaultDuration.map({ Double($0) }),
               let rate = Self.commonRates.first(where: { rate in
                   abs(1e9 * Double(rate.frame) / Double(rate.timescale) - nanoseconds) < 2
               }) {
                timescale = rate.timescale * 1000
                frameDuration = rate.frame * 1000
                frameNanoseconds = 1e9 * Double(rate.frame) / Double(rate.timescale)
            } else {
                // The file's own times, in a timescale of 1000 for
                // milliseconds or finer when its timestamps are.
                timescale = CMTimeScale(max(1, min(1_000_000_000 / max(scale, 1), 1_000_000)))
                frameDuration = nil
                frameNanoseconds = nil
            }
        }

        func value(for time: Int64) -> Int64 {
            let nanoseconds = Double(time) * nanosecondsPerUnit
            guard let frameNanoseconds, let frameDuration else {
                return Int64((nanoseconds * Double(timescale) / 1e9).rounded())
            }
            let origin = Int64((originNanoseconds * Double(timescale) / 1e9).rounded())
            return origin + Int64(((nanoseconds - originNanoseconds) / frameNanoseconds).rounded()) * frameDuration
        }
    }

    // MARK: Audio

    private static func audioPlan(_ track: MatroskaIndex.Track, scale: UInt64, bytes: Data) throws -> TrackPlan {
        guard let formatID = audioCodec(track), track.sampleRate > 0 else {
            throw MatroskaError.unsupported("its sound's format can't be read")
        }
        let rate = track.sampleRate
        let timescale = CMTimeScale(rate.rounded())
        var description = AudioStreamBasicDescription()
        description.mSampleRate = rate
        description.mFormatID = formatID
        description.mChannelsPerFrame = UInt32(track.channels)
        var cookie: Data?
        let packetFrames: (Data.SubSequence) -> Int64

        switch formatID {
        case kAudioFormatMPEG4AAC:
            guard let config = track.codecPrivate else { throw MatroskaError.unsupported("its AAC sound has no configuration") }
            description.mFramesPerPacket = 1024
            cookie = esdsCookie(audioSpecificConfig: config)
            packetFrames = { _ in 1024 }
        case kAudioFormatFLAC:
            guard let header = track.codecPrivate, let flac = FLACConfiguration(codecPrivate: header) else {
                throw MatroskaError.unsupported("its FLAC sound has no configuration")
            }
            description.mFormatFlags = flac.formatFlags
            description.mFramesPerPacket = flac.minimumBlockSize == flac.maximumBlockSize ? UInt32(flac.maximumBlockSize) : 0
            cookie = flac.cookie
            packetFrames = { frame in Int64(FLACConfiguration.blockSize(of: frame) ?? Int(flac.maximumBlockSize)) }
        default:
            let bytesPerFrame = UInt32(max(track.bitDepth, 8) / 8) * UInt32(track.channels)
            description.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            description.mBitsPerChannel = UInt32(track.bitDepth)
            description.mBytesPerFrame = bytesPerFrame
            description.mBytesPerPacket = bytesPerFrame
            description.mFramesPerPacket = 1
            packetFrames = { frame in Int64(frame.count) / Int64(bytesPerFrame) }
        }

        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytesIfPresent { pointer, count in
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: count, magicCookie: pointer, extensions: nil, formatDescriptionOut: &format
            )
        }
        guard status == noErr, let format else { throw MatroskaError.unsupported("its sound's configuration can't be read") }

        // Sound plays straight through from its first block: each packet
        // starts where the one before ended, counted in samples, so the
        // millisecond times of the blocks don't round the sound's timing.
        let firstTime = track.frames.first.map { Double($0.time) * Double(scale) / 1e9 } ?? 0
        let start = Int64((firstTime * rate).rounded())
        var time = start
        var samples: [TrackPlan.Sample] = []
        samples.reserveCapacity(track.frames.count)
        let isPCM = formatID == kAudioFormatLinearPCM
        for frame in track.frames {
            guard frame.offset + frame.size <= bytes.count else { throw MatroskaError.malformed("a frame runs past the end") }
            let frames = max(packetFrames(bytes[frame.offset..<(frame.offset + frame.size)]), 1)
            samples.append(.init(
                offset: frame.offset, size: isPCM ? Int(description.mBytesPerFrame) : frame.size,
                count: isPCM ? Int(frames) : 1,
                decodeTime: time, presentationTime: time, duration: isPCM ? 1 : frames, isKey: true
            ))
            time += frames
        }
        // The first block's time is when its first sound after the priming
        // is heard; the priming is what the file says its codec delays by.
        // Core Media takes AAC without a say to be primed by 2112 samples,
        // more than many encoders' 1024, so it is always said.
        let priming = Int64((Double(track.codecDelay) * rate / 1e9).rounded())
        return TrackPlan(
            kind: .audio, format: format, timescale: timescale, samples: samples,
            start: CMTime(value: start, timescale: timescale), priming: priming
        )
    }

    /// An MPEG-4 ES descriptor wrapping the AudioSpecificConfig, the magic
    /// cookie Core Audio's AAC decoder takes.
    static func esdsCookie(audioSpecificConfig config: Data) -> Data {
        func descriptor(_ tag: UInt8, _ body: Data) -> Data {
            var data = Data([tag])
            // Sizes are written in four 7-bit groups, as QuickTime does.
            let size = body.count
            data.append(contentsOf: [
                UInt8(0x80 | (size >> 21) & 0x7F), UInt8(0x80 | (size >> 14) & 0x7F),
                UInt8(0x80 | (size >> 7) & 0x7F), UInt8(size & 0x7F),
            ])
            data.append(body)
            return data
        }
        var decoderConfig = Data([0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        decoderConfig.append(descriptor(0x05, config))
        var es = Data([0, 0, 0])
        es.append(descriptor(0x04, decoderConfig))
        es.append(descriptor(0x06, Data([0x02])))
        return descriptor(0x03, es)
    }

    // MARK: Writing

    private static func append(_ plan: TrackPlan, to movie: AVMutableMovie, source: URL, start: CMTime) throws {
        let trackStart = CMTimeSubtract(plan.start, start)
        let (track, skipped) = try addTrack(plan, to: movie, source: source, at: trackStart)
        // Core Media drops what it takes for a codec's priming from the start
        // of the media, AAC's 2112 samples, whatever the file says, and
        // shows the next sample where the media was placed. When that isn't
        // the file's own priming, the track is made again moved by the
        // difference, so each sample is heard when the file has it.
        let correction = CMTimeSubtract(skipped, CMTime(value: plan.priming, timescale: plan.timescale))
        guard correction != .zero else { return }
        movie.removeTrack(track)
        _ = try addTrack(plan, to: movie, source: source, at: CMTimeAdd(trackStart, correction))
    }

    /// Adds the plan's track with its media placed from `trackStart`, and
    /// returns it with how much of the media's start Core Media skipped.
    private static func addTrack(
        _ plan: TrackPlan, to movie: AVMutableMovie, source: URL, at trackStart: CMTime
    ) throws -> (AVMutableMovieTrack, skipped: CMTime) {
        let mediaType: AVMediaType = plan.kind == .video ? .video : .audio
        guard let track = movie.addMutableTrack(withMediaType: mediaType, copySettingsFrom: nil) else {
            throw MatroskaError.unsupported("a movie track couldn't be made")
        }
        track.timescale = plan.timescale

        // Decode times start at zero or later in the media; the track's
        // edit then shows the media from its first shown frame, placed
        // where it starts relative to the file's earliest track.
        let shift = max(0, -(plan.samples.first?.decodeTime ?? 0))
        for sample in plan.samples {
            let buffer = try sampleBuffer(for: sample, plan: plan, shift: shift, source: source)
            try track.append(buffer, decodeTime: nil, presentationTime: nil)
        }

        guard let first = plan.samples.map(\.presentationTime).min(),
              let last = plan.samples.map({ $0.presentationTime + $0.duration * Int64($0.count) }).max()
        else { return (track, .zero) }
        let mediaRange = CMTimeRange(
            start: CMTime(value: first + shift, timescale: plan.timescale),
            duration: CMTime(value: last - first, timescale: plan.timescale)
        )
        guard track.insertMediaTimeRange(mediaRange, into: CMTimeRange(start: trackStart, duration: mediaRange.duration)) else {
            throw MatroskaError.unsupported("a track's frames couldn't be placed")
        }
        let shown = track.segments.first { !$0.isEmpty }?.timeMapping.source.start
        return (track, shown.map { CMTimeSubtract($0, mediaRange.start) } ?? .zero)
    }

    private static func sampleBuffer(
        for sample: TrackPlan.Sample, plan: TrackPlan, shift: Int64, source: URL
    ) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: sample.duration, timescale: plan.timescale),
            presentationTimeStamp: CMTime(value: sample.presentationTime + shift, timescale: plan.timescale),
            decodeTimeStamp: CMTime(value: sample.decodeTime + shift, timescale: plan.timescale)
        )
        var size = sample.size
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: plan.format, sampleCount: sample.count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer
        )
        guard status == noErr, let buffer else { throw MatroskaError.unsupported("a frame couldn't be referenced (\(status))") }
        CMSetAttachment(buffer, key: kCMSampleBufferAttachmentKey_SampleReferenceURL, value: source as CFURL,
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
        CMSetAttachment(buffer, key: kCMSampleBufferAttachmentKey_SampleReferenceByteOffset,
                        value: NSNumber(value: sample.offset), attachmentMode: kCMAttachmentMode_ShouldPropagate)
        if !sample.isKey,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_NotSync] = true
        }
        return buffer
    }
}

/// A FLAC stream's configuration, from the Matroska track's private data:
/// "fLaC" followed by the stream's metadata blocks.
struct FLACConfiguration {
    var minimumBlockSize: UInt16
    var maximumBlockSize: UInt16
    var bitsPerSample: Int
    /// The metadata blocks, the last one marked last, as an MP4 'dfLa' box
    /// carries them.
    var blocks: Data

    init?(codecPrivate data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 + 4 + 34, bytes[0...3] == [0x66, 0x4C, 0x61, 0x43] else { return nil }
        var position = 4
        var blocks = Data()
        var streamInfo: [UInt8]?
        while position + 4 <= bytes.count {
            let type = bytes[position] & 0x7F
            let length = Int(bytes[position + 1]) << 16 | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
            guard position + 4 + length <= bytes.count else { break }
            let body = Array(bytes[(position + 4)..<(position + 4 + length)])
            if type == 0 { streamInfo = body }
            let isLast = position + 4 + length >= bytes.count
            blocks.append((isLast ? 0x80 : 0) | type)
            blocks.append(contentsOf: bytes[(position + 1)...(position + 3)])
            blocks.append(contentsOf: body)
            position += 4 + length
        }
        guard let info = streamInfo, info.count >= 18 else { return nil }
        minimumBlockSize = UInt16(info[0]) << 8 | UInt16(info[1])
        maximumBlockSize = UInt16(info[2]) << 8 | UInt16(info[3])
        bitsPerSample = Int((info[12] & 0x01) << 4 | info[13] >> 4) + 1
        self.blocks = blocks
    }

    /// Core Audio's FLAC decoder takes a 'dfLa' box as its magic cookie.
    var cookie: Data {
        var body = Data([0, 0, 0, 0])
        body.append(blocks)
        var box = withUnsafeBytes(of: UInt32(8 + body.count).bigEndian) { Data($0) }
        box.append(contentsOf: Array("dfLa".utf8))
        box.append(body)
        return box
    }

    var formatFlags: AudioFormatFlags {
        switch bitsPerSample {
        case 16: kAppleLosslessFormatFlag_16BitSourceData
        case 20: kAppleLosslessFormatFlag_20BitSourceData
        case 24: kAppleLosslessFormatFlag_24BitSourceData
        case 32: kAppleLosslessFormatFlag_32BitSourceData
        default: 0
        }
    }

    /// How many samples a FLAC frame holds, from its header; nil when the
    /// header can't be read.
    static func blockSize(of frame: Data.SubSequence) -> Int? {
        let bytes = Array(frame.prefix(16))
        guard bytes.count >= 5, bytes[0] == 0xFF, bytes[1] & 0xFE == 0xF8 else { return nil }
        let code = Int(bytes[2] >> 4)
        switch code {
        case 1: return 192
        case 2...5: return 576 << (code - 2)
        case 8...15: return 256 << (code - 8)
        case 6, 7:
            // The frame or sample number, UTF-8 coded, comes first.
            let lead = bytes[4]
            let numberLength = lead < 0x80 ? 1 : lead.leadingZeroBitCount == 0 ? 1 : (~lead).leadingZeroBitCount
            let at = 4 + numberLength
            guard at + (code == 6 ? 1 : 2) <= bytes.count else { return nil }
            return code == 6 ? Int(bytes[at]) + 1 : (Int(bytes[at]) << 8 | Int(bytes[at + 1])) + 1
        default: return nil
        }
    }
}

private extension Optional where Wrapped == Data {
    func withUnsafeBytesIfPresent<Result>(_ body: (UnsafeRawPointer?, Int) -> Result) -> Result {
        guard let data = self else { return body(nil, 0) }
        return data.withUnsafeBytes { body($0.baseAddress, $0.count) }
    }
}
