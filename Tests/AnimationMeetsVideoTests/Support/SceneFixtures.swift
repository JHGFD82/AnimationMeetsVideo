import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// One frame of a fixture movie: when it is shown and what it looks like.
struct FixtureFrame {
    var pts: CMTime
    /// Color of the pixel at (x, y), 8 bits each of red, green and blue.
    var color: @Sendable (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8)
}

enum SceneFixture {
    static let width = 128, height = 72

    static func gray(_ value: Int) -> @Sendable (Int, Int) -> (UInt8, UInt8, UInt8) {
        let v = UInt8(min(max(value, 0), 255))
        return { _, _ in (v, v, v) }
    }

    /// A busy picture: diagonal stripes, so a sideways move changes many pixels.
    static func stripes(shift: Int, base: Int = 60, contrast: Int = 120) -> @Sendable (Int, Int) -> (UInt8, UInt8, UInt8) {
        { x, y in
            let on = ((x + y + shift) / 8) % 2 == 0
            let v = UInt8(on ? base + contrast : base)
            return (v, v, v)
        }
    }

    /// Two striped shots cross-faded over `length` frames starting at frame `from`.
    static func dissolve(at index: Int, from: Int, length: Int) -> @Sendable (Int, Int) -> (UInt8, UInt8, UInt8) {
        let a = stripes(shift: 0, base: 20), b = stripes(shift: 4, base: 140, contrast: 60)
        let mix = min(max(Double(index - from) / Double(length), 0), 1)
        return { x, y in
            let p = Double(a(x, y).0), q = Double(b(x, y).0)
            let v = UInt8(p * (1 - mix) + q * mix)
            return (v, v, v)
        }
    }

    static func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> @Sendable (Int, Int) -> (UInt8, UInt8, UInt8) {
        { _, _ in (r, g, b) }
    }

    /// Gray `from` until frame `start`, then a linear change to `to` over `length` frames.
    static func fade(at index: Int, from: Int, to: Int, start: Int, length: Int) -> @Sendable (Int, Int) -> (UInt8, UInt8, UInt8) {
        let progress = min(max(Double(index - start) / Double(length), 0), 1)
        return gray(Int(Double(from) + Double(to - from) * progress))
    }

    /// Frames at a constant rate: `count` frames starting at frame `first`.
    static func constantRate(_ first: Int = 0, count: Int, fps: Int32 = 24, timescale: Int32? = nil, start: CMTime = .zero,
                             color: @escaping @Sendable (Int) -> @Sendable (Int, Int) -> (UInt8, UInt8, UInt8)) -> [FixtureFrame] {
        let scale = timescale ?? fps
        return (0..<count).map { index in
            let pts = CMTimeAdd(start, CMTime(value: Int64(first + index) * Int64(scale) / Int64(fps), timescale: scale))
            return FixtureFrame(pts: pts, color: color(first + index))
        }
    }

    /// Writes the frames as an H.264 movie, one movie at a time, trying again
    /// when the encoder fails for reasons unrelated to what a test checks.
    static func write(_ frames: [FixtureFrame], to url: URL, sessionStart: CMTime = .zero, mediaTimeScale: Int32? = nil) async throws {
        await MovieWriterGate.shared.enter()
        var failure = "unknown"
        for attempt in 1...4 {
            try? FileManager.default.removeItem(at: url)
            do {
                if let error = try await writeOnce(frames, to: url, sessionStart: sessionStart, mediaTimeScale: mediaTimeScale) {
                    failure = error
                } else {
                    await MovieWriterGate.shared.leave()
                    return
                }
            } catch {
                await MovieWriterGate.shared.leave()
                throw error
            }
            try? await Task.sleep(for: .milliseconds(100 * attempt))
        }
        await MovieWriterGate.shared.leave()
        Issue.record("Couldn't write a fixture movie: \(failure)")
        throw CocoaError(.fileWriteUnknown)
    }

    private static func writeOnce(_ frames: [FixtureFrame], to url: URL, sessionStart: CMTime, mediaTimeScale: Int32?) async throws -> String? {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        if let mediaTimeScale { input.mediaTimeScale = mediaTimeScale }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { return writer.error?.localizedDescription ?? "couldn't start" }
        writer.startSession(atSourceTime: sessionStart)
        for frame in frames {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { return writer.error?.localizedDescription ?? "failed while writing" }
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height {
                for x in 0..<width {
                    let (r, g, b) = frame.color(x, y)
                    let offset = y * stride + x * 4
                    base[offset] = b; base[offset + 1] = g; base[offset + 2] = r; base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: frame.pts)
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? nil : (writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "amv-fixture-\(UUID().uuidString).mov")
    }

    /// Scores a freshly written fixture and removes it.
    static func score(_ frames: [FixtureFrame], sessionStart: CMTime = .zero, mediaTimeScale: Int32? = nil) async throws -> (track: ChangeScoreTrack, duration: CMTime) {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await write(frames, to: url, sessionStart: sessionStart, mediaTimeScale: mediaTimeScale)
        let track = try await FrameScorer.score(url: url)
        let duration = try await AVURLAsset(url: url).load(.duration)
        return (track, duration)
    }
}
