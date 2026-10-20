import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A Matroska fixture and the reference movie made from it, deleted when
/// the test is done.
private struct Made {
    var mkv: URL
    var movie: URL
    var source: MatroskaFixture.Source
    var index: MatroskaIndex

    static func make(_ options: MatroskaFixture.Options = .init()) async throws -> Made {
        let name = "amv-mkv-\(UUID().uuidString)"
        let mkv = FileManager.default.temporaryDirectory.appending(path: "\(name).mkv")
        let movie = FileManager.default.temporaryDirectory.appending(path: "\(name).mov")
        let source = try await MatroskaFixture.write(to: mkv, options: options)
        let index = try MatroskaIndex.read(mkv)
        try MatroskaReferenceMovie.write(index: index, source: mkv, to: movie)
        return Made(mkv: mkv, movie: movie, source: source, index: index)
    }

    func remove() {
        for url in [mkv, movie, source.movie] { try? FileManager.default.removeItem(at: url) }
    }
}

/// When the white frame is shown, and when the beep is first heard, read
/// from the movie as the app reads media.
private func flashAndBeep(_ url: URL) async throws -> (flash: Double, beep: Double) {
    let asset = AVURLAsset(url: url)
    let reader = try AVAssetReader(asset: asset)
    let video = AVAssetReaderTrackOutput(
        track: try #require(try await asset.loadTracks(withMediaType: .video).first),
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    let sound = AVAssetReaderTrackOutput(
        track: try #require(try await asset.loadTracks(withMediaType: .audio).first),
        outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                         AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1]
    )
    reader.add(video)
    reader.add(sound)
    try #require(reader.startReading())
    var flash: Double?
    while let buffer = video.copyNextSampleBuffer() {
        guard flash == nil, let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let center = CVPixelBufferGetBaseAddress(pixels)!.load(
            fromByteOffset: CVPixelBufferGetBytesPerRow(pixels) * MatroskaFixture.height / 2 + MatroskaFixture.width * 2,
            as: UInt8.self
        )
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        if center > 200 { flash = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
    }
    var beep: Double?
    while let buffer = sound.copyNextSampleBuffer() {
        guard beep == nil, let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        if let first = samples.firstIndex(where: { abs($0) > 0.05 }) {
            beep = CMSampleBufferGetPresentationTimeStamp(buffer).seconds + Double(first) / MatroskaFixture.sampleRate
        }
    }
    return (try #require(flash), try #require(beep))
}

/// Every decoded frame's time and a hash of its pixels.
private func decodedFrames(_ url: URL) async throws -> [(time: Double, hash: String)] {
    let asset = AVURLAsset(url: url)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: try #require(try await asset.loadTracks(withMediaType: .video).first),
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    reader.add(output)
    try #require(reader.startReading())
    var frames: [(Double, String)] = []
    while let buffer = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(buffer) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let data = Data(bytes: CVPixelBufferGetBaseAddress(pixels)!, count: CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        frames.append((CMSampleBufferGetPresentationTimeStamp(buffer).seconds, SHA256.hash(data: data).description))
    }
    try #require(reader.status == .completed)
    return frames
}

@Suite(.serialized) struct MatroskaReferenceMovieTests {
    @Test func indexFindsEveryFrameWhereItsBytesAre() async throws {
        let made = try await Made.make()
        defer { made.remove() }
        let bytes = try Data(contentsOf: made.mkv)

        let video = try #require(made.index.tracks.first { $0.kind == .video })
        let sound = try #require(made.index.tracks.first { $0.kind == .audio })
        #expect(video.codecID == "V_MPEG4/ISO/AVC")
        #expect(video.frames.map { bytes[$0.offset..<($0.offset + $0.size)] } == made.source.video.map { $0.data[...] })
        #expect(video.frames.map(\.isKey) == made.source.video.map(\.isKey))
        #expect(sound.frames.map { bytes[$0.offset..<($0.offset + $0.size)] } == made.source.sound.map { $0.data[...] })
        #expect(sound.codecDelay > 0)
    }

    @Test(arguments: [
        MatroskaFixture.Options(lacing: .xiph),
        MatroskaFixture.Options(lacing: .ebml),
        MatroskaFixture.Options(unknownSizeClusters: true),
        MatroskaFixture.Options(blockGroups: true),
    ])
    func indexReadsEveryWayOfStoringFrames(_ options: MatroskaFixture.Options) async throws {
        let made = try await Made.make(options)
        defer { made.remove() }
        let bytes = try Data(contentsOf: made.mkv)

        let video = try #require(made.index.tracks.first { $0.kind == .video })
        let sound = try #require(made.index.tracks.first { $0.kind == .audio })
        #expect(video.frames.map { bytes[$0.offset..<($0.offset + $0.size)] } == made.source.video.map { $0.data[...] })
        #expect(video.frames.map(\.isKey) == made.source.video.map(\.isKey))
        #expect(sound.frames.map { bytes[$0.offset..<($0.offset + $0.size)] } == made.source.sound.map { $0.data[...] })
    }

    @Test func movieHoldsOnlyTheIndex() async throws {
        let made = try await Made.make()
        defer { made.remove() }

        // It points at the Matroska file, and none of the frames are in it.
        let movie = try Data(contentsOf: made.movie)
        #expect(movie.range(of: Data(made.mkv.lastPathComponent.utf8)) != nil)
        let largest = try #require(made.source.video.max { $0.data.count < $1.data.count })
        #expect(movie.range(of: largest.data) == nil)
        #expect(movie.count < (try Data(contentsOf: made.mkv)).count)
    }

    @Test func movieDecodesTheSameFramesAtTheSameTimes() async throws {
        let made = try await Made.make()
        defer { made.remove() }

        let original = try await decodedFrames(made.source.movie)
        let referenced = try await decodedFrames(made.movie)
        #expect(referenced.count == MatroskaFixture.frames)
        #expect(referenced.map(\.hash) == original.map(\.hash))
        #expect(zip(referenced, original).allSatisfy { abs($0.time - $1.time) < 0.000_1 })

        let asset = AVURLAsset(url: made.movie)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.nominalFrameRate) == Float(MatroskaFixture.fps))
        #expect(try await track.load(.timeRange) == CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1)))
    }

    @Test(arguments: [
        MatroskaFixture.Options(sound: .aac, priming: .codecDelay),
        MatroskaFixture.Options(sound: .aac, priming: .videoStartsLater),
        MatroskaFixture.Options(sound: .flac),
    ])
    func soundStaysInSyncWithThePicture(_ options: MatroskaFixture.Options) async throws {
        let made = try await Made.make(options)
        defer { made.remove() }

        let (flash, beep) = try await flashAndBeep(made.movie)
        // Matroska keeps times to the millisecond.
        #expect(abs(beep - flash) < 0.001_5, "flash at \(flash), beep at \(beep)")
        let late = options.priming == .videoStartsLater ? Double(made.source.priming) / MatroskaFixture.sampleRate : 0
        #expect(abs(flash - (1 + late)) < 0.001_5)
    }

    @Test func movieWorksInACompositionAndFrameByFrame() async throws {
        let made = try await Made.make()
        defer { made.remove() }
        let asset = AVURLAsset(url: made.movie)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (_, shown) = try await generator.image(at: CMTime(value: 37, timescale: 25))
        #expect(shown == CMTime(value: 37, timescale: 25))

        let composition = AVMutableComposition()
        try await composition.insertTimeRange(
            CMTimeRange(start: CMTime(value: 1, timescale: 2), duration: CMTime(value: 1, timescale: 1)), of: asset, at: .zero
        )
        let output = FileManager.default.temporaryDirectory.appending(path: "amv-mkv-export-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleProRes422LPCM))
        try await session.export(to: output, as: .mov)
        let exported = AVURLAsset(url: output)
        #expect(abs(try await exported.load(.duration).seconds - 1) < 0.001)
        #expect(try await exported.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func refusesFilesItCantUse() throws {
        #expect(throws: MatroskaError.self) { try MatroskaIndex.read(Data("not a matroska file".utf8)) }

        var index = MatroskaIndex()
        index.tracks = [MatroskaIndex.Track(number: 1, kind: .video, codecID: "V_VP9")]
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-mkv-\(UUID().uuidString).mov")
        #expect(throws: MatroskaError.self) { try MatroskaReferenceMovie.write(index: index, source: url, to: url) }
    }
}

@Suite struct MatroskaVideoTimingTests {
    private func track(frameNanoseconds: UInt64?) -> MatroskaIndex.Track {
        MatroskaIndex.Track(number: 1, kind: .video, codecID: "V_MPEG4/ISO/AVC", defaultDuration: frameNanoseconds)
    }

    @Test func millisecondTimesSnapToTheFramesOfACommonRate() {
        let timing = MatroskaReferenceMovie.VideoTiming(track: track(frameNanoseconds: 33_366_666), scale: 1_000_000, origin: 0)
        #expect(timing.timescale == 30_000_000)
        // Frame 100 of 29.97 fps is at 3336.67 ms, kept as 3337.
        #expect(CMTime(value: timing.value(for: 3_337), timescale: timing.timescale) == CMTime(value: 100_100, timescale: 30_000))
    }

    @Test func thirtyIsntTakenForTwentyNineNineSeven() {
        let timing = MatroskaReferenceMovie.VideoTiming(track: track(frameNanoseconds: 33_333_333), scale: 1_000_000, origin: 0)
        #expect(CMTime(value: timing.value(for: 3_333), timescale: timing.timescale) == CMTime(value: 100, timescale: 30))
    }

    @Test func aTrackThatStartsBetweenFramesKeepsItsStart() {
        let timing = MatroskaReferenceMovie.VideoTiming(track: track(frameNanoseconds: 40_000_000), scale: 1_000_000, origin: 21)
        #expect(CMTime(value: timing.value(for: 21), timescale: timing.timescale) == CMTime(value: 21, timescale: 1_000))
        #expect(CMTime(value: timing.value(for: 61), timescale: timing.timescale) == CMTime(value: 61, timescale: 1_000))
    }

    @Test func otherRatesKeepTheFilesTimes() {
        let timing = MatroskaReferenceMovie.VideoTiming(track: track(frameNanoseconds: nil), scale: 1_000_000, origin: 0)
        #expect(timing.timescale == 1_000)
        #expect(timing.value(for: 1_234) == 1_234)
    }
}

@Suite struct FLACConfigurationTests {
    @Test func readsBlockSizesFromFrameHeaders() {
        // Sync code, then the block size code in the high nibble.
        #expect(FLACConfiguration.blockSize(of: Data([0xFF, 0xF8, 0xC9, 0x08, 0x00])[...]) == 4_096)
        #expect(FLACConfiguration.blockSize(of: Data([0xFF, 0xF8, 0x19, 0x08, 0x00])[...]) == 192)
        // Code 7: a 16-bit size minus one after the frame number.
        #expect(FLACConfiguration.blockSize(of: Data([0xFF, 0xF8, 0x79, 0x08, 0x05, 0x01, 0x2B])[...]) == 300)
        #expect(FLACConfiguration.blockSize(of: Data([0x00, 0x00, 0x00, 0x00, 0x00])[...]) == nil)
    }
}
