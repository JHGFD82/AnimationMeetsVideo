import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Picture and sound in sync through a real export (code-review-plan.md,
/// phase 5, "End-to-end sync"): numbered footage that flashes white every
/// twelve frames, and a WAV with a click on the sample each flash starts,
/// placed together on a timeline at the footage's rate. The exported movie
/// is read back: every white frame must be the numbered frame meant, on the
/// timeline frame meant, and every click within half a frame of its white
/// frame (the plan's bound), and within 2 ms (sound keeps its timing to the
/// sample; a frame of 60 fps is 16.7 ms). Read back with AVFoundation; an
/// independent prober (ffprobe) isn't on the reviewing Mac.
///
/// `REVIEW_SYNC_LONG=1` also places the pair just before ten minutes on a
/// 24 fps timeline, for drift; it exports ten minutes, so it is slow.
@Suite(.serialized) struct EndToEndSyncTests {
    private static let flashEvery = 12
    private static let frames = 48

    struct Measured {
        var flashes: [(number: Int, time: Double)] = []
        var clicks: [Double] = []
    }

    /// Writes the pair at frame duration `frame`, places both `offset`
    /// frames into a timeline of that rate (`lead` seconds of nothing
    /// before them on top), exports ProRes 422 and reads it back.
    private func exportAndMeasure(frame: CMTime, offsetFrames: Int, leadSeconds: Double = 0) async throws -> Measured {
        let directory = FileManager.default.temporaryDirectory.appending(path: "amv-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appending(path: "flashes.mov"), clicks = directory.appending(path: "clicks.wav")
        let length = CMTimeMultiply(frame, multiplier: Int32(Self.frames))
        try await ReviewFixtures.writeMovie(
            to: movie, picture: .flashes(every: Self.flashEvery, hold: 1), timing: .constant(frame), count: Self.frames, keyFrameInterval: 24
        )
        let flashFrames = stride(from: 0, to: Self.frames, by: Self.flashEvery).map { $0 }
        try ReviewFixtures.writeClicks(
            to: clicks, at: flashFrames.map { ReviewFixtures.sample(ofFrame: $0, duration: frame) }, seconds: length.seconds
        )

        var project = EditingProject.empty
        let rate = Double(frame.timescale) / Double(frame.value)
        project.timelines[0].frameRate = rate
        project.timelines[0].frameSize = CGSize(width: ReviewFixtures.width, height: ReviewFixtures.height)
        let picture = MediaClip(
            name: "Flashes", kind: .video, url: movie, duration: length, frameRate: rate, colorSpace: .rec709, codecName: "H.264"
        )
        var sound = MediaClip(
            name: "Clicks", kind: .audio, url: clicks, duration: CMTime(value: CMTimeValue(length.seconds * 48_000), timescale: 48_000),
            frameRate: 0, colorSpace: .rec709, codecName: "PCM"
        )
        sound.hasAudio = true
        project.addMedia(picture)
        project.addMedia(sound)
        let lead = project.timelines[0].frameAligned(CMTime(seconds: leadSeconds, preferredTimescale: 600), .nearest)
        let start = CMTimeAdd(lead, CMTimeMultiply(frame, multiplier: Int32(offsetFrames)))
        project.timelines[0].layers = [
            TimelineLayer(customName: nil, kind: .video, clips: [
                TimelineClip(source: .media(picture.id), startOffset: start, trimStart: .zero, trimEnd: length),
            ]),
            TimelineLayer(customName: nil, kind: .sound, clips: [
                TimelineClip(source: .media(sound.id), startOffset: start, trimStart: .zero, trimEnd: sound.duration),
            ]),
        ]

        let exported = directory.appending(path: "export.mov")
        _ = try await CompositionExporter.export(project: project, timelineID: project.rootTimelineID, preset: .proRes422, to: exported)
        return try await measure(exported)
    }

    /// The white frames (with the numbers their barcodes read) and the
    /// clicks' first samples, in seconds of the movie.
    private func measure(_ url: URL) async throws -> Measured {
        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let pictures = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let sound = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
        reader.add(pictures)
        reader.add(sound)
        #expect(reader.startReading())
        var measured = Measured()
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        while let sample = pictures.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let image = CIImage(cvPixelBuffer: pixels)
            guard let cg = context.createCGImage(image, from: image.extent) else { continue }
            // Below the barcode: white on a flash, the drawing otherwise.
            guard let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { continue }
            let offset = (cg.height * 3 / 4) * cg.bytesPerRow + (cg.width / 2) * (cg.bitsPerPixel / 8)
            let luma = (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
            if luma > 230, let number = ReviewFixtures.frameNumber(in: cg) { measured.flashes.append((number, time)) }
        }
        // The movie starts in silence: a click on its first sample counts.
        var quiet = Int.max / 2
        while let sample = sound.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            for (index, value) in values.enumerated() {
                if abs(value) > 0.5 {
                    if quiet > 2_400 { measured.clicks.append(start + Double(index) / 48_000) }
                    quiet = 0
                } else {
                    quiet += 1
                }
            }
        }
        #expect(reader.status == .completed)
        return measured
    }

    private func check(_ measured: Measured, frame: CMTime, firstFrameAt start: Double) {
        let frameSeconds = frame.seconds
        let flashFrames = stride(from: 0, to: Self.frames, by: Self.flashEvery).map { $0 }
        // Every flash, on the numbered frame meant, on the timeline frame meant.
        #expect(measured.flashes.map(\.number) == flashFrames)
        for flash in measured.flashes {
            let meant = start + Double(flash.number) * frameSeconds
            #expect(abs(flash.time - meant) < frameSeconds / 2, "frame \(flash.number) at \(flash.time), meant \(meant)")
        }
        #expect(measured.clicks.count == flashFrames.count, "clicks at \(measured.clicks)")
        var worst = 0.0
        for (flash, click) in zip(measured.flashes, measured.clicks) {
            let error = click - flash.time
            worst = max(worst, abs(error))
            #expect(abs(error) < frameSeconds / 2, "click \(error * 1000) ms from frame \(flash.number)")
            #expect(abs(error) < 0.002, "click \(error * 1000) ms from frame \(flash.number)")
        }
        print("EndToEndSync: \(1 / frameSeconds) fps from \(start) s, worst click \(worst * 1000) ms from its frame")
    }

    @Test(arguments: [
        CMTime(value: 1, timescale: 24), CMTime(value: 1001, timescale: 30_000), CMTime(value: 1, timescale: 60),
    ])
    func eachClickIsHeardOnItsWhiteFrame(frame: CMTime) async throws {
        for offset in [0, 7, 13] {
            let measured = try await exportAndMeasure(frame: frame, offsetFrames: offset)
            check(measured, frame: frame, firstFrameAt: Double(offset) * frame.seconds)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REVIEW_SYNC_LONG"] != nil), .timeLimit(.minutes(20)))
    func theyStayInSyncNearTheEndOfTenMinutes() async throws {
        let frame = CMTime(value: 1, timescale: 24)
        let lead = 598.0
        let measured = try await exportAndMeasure(frame: frame, offsetFrames: 3, leadSeconds: lead)
        check(measured, frame: frame, firstFrameAt: lead + 3 * frame.seconds)
    }
}
