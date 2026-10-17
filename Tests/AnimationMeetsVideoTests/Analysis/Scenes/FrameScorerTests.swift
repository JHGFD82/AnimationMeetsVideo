import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Writes a small H.264 movie of solid-color frames: `segments` is a list of
/// (luma, frame count). Lets tests run real decoding without footage.
///
/// Movies are written one at a time, and a failed write is tried again: on
/// CI's virtual Macs the H.264 encoder fails now and then when many tests
/// write at once, which has nothing to do with what the tests check.
func writeMovie(to url: URL, segments: [(luma: UInt8, frames: Int)], fps: Int32 = 24) async throws {
    await MovieWriterGate.shared.enter()
    var failure = "unknown"
    for attempt in 1...4 {
        try? FileManager.default.removeItem(at: url)
        do {
            if let error = try await writeMovieOnce(to: url, segments: segments, fps: fps) {
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
    Issue.record("Couldn't write a test movie after four tries: \(failure)")
    throw CocoaError(.fileWriteUnknown)
}

/// One try at `writeMovie`; returns why it failed, or nil once written.
private func writeMovieOnce(to url: URL, segments: [(luma: UInt8, frames: Int)], fps: Int32) async throws -> String? {
    let width = 128, height = 72
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { return writer.error?.localizedDescription ?? "couldn't start" }
    writer.startSession(atSourceTime: .zero)

    var frameIndex: Int64 = 0
    for segment in segments {
        for _ in 0..<segment.frames {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { return writer.error?.localizedDescription ?? "failed while writing" }
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(segment.luma), CVPixelBufferGetBytesPerRow(pixels) * height)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: frameIndex, timescale: fps))
            frameIndex += 1
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    return writer.status == .completed ? nil : (writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
}

/// Lets one test movie be written at a time.
actor MovieWriterGate {
    static let shared = MovieWriterGate()
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

@Suite struct FrameScorerTests {
    private func temporaryMovie() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "amv-score-\(UUID().uuidString).mov")
    }

    @Test func scoresEveryFrameAndFindsTheCuts() async throws {
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeMovie(to: url, segments: [(0, 24), (255, 24), (128, 24)])

        let track = try await FrameScorer.score(url: url)

        #expect(track.frameCount == 72)
        #expect(track.scores[0] == 0)
        #expect(zip(track.times, track.times.dropFirst()).allSatisfy { $0 < $1 })

        let cuts = SceneDetector.autoCuts(in: track, defaultSensitivity: SceneDetector.balancedSensitivity)
        #expect(cuts.map(\.seconds) == [1, 2])
    }

    @Test func aStaticShotHasNoCuts() async throws {
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeMovie(to: url, segments: [(100, 48)])

        let track = try await FrameScorer.score(url: url)

        #expect(track.frameCount == 48)
        #expect(SceneDetector.autoCuts(in: track, defaultSensitivity: 1).isEmpty)
    }

    @Test func reportsProgressUpToOne() async throws {
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeMovie(to: url, segments: [(0, 60), (255, 60)])

        let reported = LockedBox<[Double]>([])
        _ = try await FrameScorer.score(url: url) { value in reported.mutate { $0.append(value) } }

        let values = reported.value
        #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func rejectsAFileWithoutVideo() async throws {
        let url = temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a movie".utf8).write(to: url)

        await #expect(throws: (any Error).self) {
            try await FrameScorer.score(url: url)
        }
    }

    @Test func meanDifferenceIsTheAverageAbsoluteChange() {
        #expect(FrameScorer.meanAbsoluteDifference([0, 0, 0, 0], [10, 10, 30, 30]) == 20)
        #expect(FrameScorer.meanAbsoluteDifference([5, 5], [5, 5]) == 0)
        #expect(FrameScorer.meanAbsoluteDifference([0], [255]) == 255)
        #expect(FrameScorer.meanAbsoluteDifference([1, 2], [1]) == 0)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
