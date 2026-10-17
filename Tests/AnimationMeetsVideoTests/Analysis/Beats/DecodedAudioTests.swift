import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A sample buffer as the reader hands them out: `count` samples (by
/// default, one per value) of `bytes` at `presentation`, described as
/// interleaved PCM with the given layout.
func pcmBuffer(
    _ values: [Float], at presentation: CMTime = .zero, count: Int? = nil, bytes: Data? = nil,
    sampleRate: Double = BeatDetector.sampleRate, channels: UInt32 = 1, bits: UInt32 = 32,
    flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
) throws -> CMSampleBuffer {
    let data = bytes ?? values.withUnsafeBytes { Data($0) }
    var description = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
        mBytesPerPacket: bits / 8 * channels, mFramesPerPacket: 1, mBytesPerFrame: bits / 8 * channels,
        mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0
    )
    var format: CMAudioFormatDescription?
    try #require(CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &format
    ) == noErr)
    var block: CMBlockBuffer?
    if !data.isEmpty {
        try #require(CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr)
        let status = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: data.count) }
        try #require(status == kCMBlockBufferNoErr)
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)), presentationTimeStamp: presentation, decodeTimeStamp: .invalid
    )
    var buffer: CMSampleBuffer?
    try #require(CMSampleBufferCreate(
        allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: format, sampleCount: count ?? values.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer
    ) == noErr)
    return try #require(buffer)
}

private func isMalformed(_ make: () throws -> CMSampleBuffer) -> Bool {
    do {
        _ = try BeatDetector.pcmSamples(of: make())
        return false
    } catch BeatDetector.DetectionError.malformedAudio {
        return true
    } catch {
        return false
    }
}

@Suite struct DecodedAudioTests {
    @Test func samplesOfAWellFormedBufferAreReadBack() throws {
        let values: [Float] = [0, 0.5, -0.25, 1]
        #expect(try BeatDetector.pcmSamples(of: pcmBuffer(values)) == values)
    }

    @Test func aBufferWithNothingInItIsEmptyNotAnError() throws {
        #expect(try BeatDetector.pcmSamples(of: pcmBuffer([])).isEmpty)
    }

    @Test func buffersInAnotherFormatAreMalformed() {
        #expect(isMalformed { try pcmBuffer([0, 0], channels: 2) }, "stereo")
        #expect(isMalformed { try pcmBuffer([], count: 2, bytes: Data(count: 4), bits: 16, flags: kAudioFormatFlagIsSignedInteger) }, "16-bit integer")
        #expect(isMalformed { try pcmBuffer([0, 0], sampleRate: 44_100) }, "another rate")
        #expect(isMalformed { try pcmBuffer([0, 0], flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian) }, "big endian")
    }

    @Test func aByteCountThatDoesntMatchTheSamplesIsMalformed() {
        #expect(isMalformed { try pcmBuffer([0, 0, 0], count: 4) }, "too few bytes")
        #expect(isMalformed { try pcmBuffer([0, 0, 0], count: 2) }, "too many bytes")
        #expect(isMalformed { try pcmBuffer([], count: 1, bytes: Data(count: 6)) }, "not whole samples")
        #expect(isMalformed { try pcmBuffer([], count: 3) }, "samples with no data")
        #expect(isMalformed { try pcmBuffer([], count: 0, bytes: Data(count: 8)) }, "data with no samples")
    }
}

/// Collects what `TimedSamples` hands on.
private final class Collected {
    var samples: [Float] = []
}

private func timed(longestGap: Int64 = 1_000) -> (TimedSamples, Collected) {
    let collected = Collected()
    return (TimedSamples(longestGap: longestGap) { collected.samples += $0 }, collected)
}

/// `count` samples in, at the detector's rate.
private func at(_ count: Int64) -> CMTime { CMTime(value: count, timescale: CMTimeScale(BeatDetector.sampleRate)) }

@Suite struct TimedSamplesTests {
    @Test func aLateStartSetsTheOrigin() throws {
        var (placer, collected) = timed()
        try placer.append([1, 1], at: CMTime(seconds: 2, preferredTimescale: 600))
        #expect(placer.origin == Int64(2 * BeatDetector.sampleRate))
        let expected: [Float] = [1, 1]
        #expect(collected.samples == expected)
    }

    @Test func theOriginComesFromTheFirstBufferWithSamples() throws {
        var (placer, collected) = timed()
        try placer.append([], at: at(5))
        try placer.append([1], at: at(9))
        #expect(placer.origin == 9)
        let expected: [Float] = [1]
        #expect(collected.samples == expected)
    }

    @Test func aGapIsFilledWithSilence() throws {
        var (placer, collected) = timed()
        try placer.append([1, 1, 1, 1], at: at(100))
        try placer.append([2, 2], at: at(110))
        try placer.append([3], at: at(112))
        let expected: [Float] = [1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 2, 2, 3]
        #expect(collected.samples == expected)
        #expect(placer.fed == 13)
    }

    @Test func anOverlapIsDroppedOnce() throws {
        var (placer, collected) = timed()
        try placer.append([1, 1, 1, 1, 1, 1], at: at(0))
        try placer.append([2, 2, 2, 2], at: at(3))
        // Entirely covered already.
        try placer.append([3, 3], at: at(4))
        try placer.append([4], at: at(7))
        let expected: [Float] = [1, 1, 1, 1, 1, 1, 2, 4]
        #expect(collected.samples == expected)
    }

    @Test func roundingBetweenTimescalesIsNotAGap() throws {
        var (placer, collected) = timed()
        try placer.append([1, 1, 1, 1], at: at(0))
        try placer.append([2], at: at(5))
        try placer.append([3], at: at(4))
        let expected: [Float] = [1, 1, 1, 1, 2, 3]
        #expect(collected.samples == expected)
    }

    @Test func otherTimescalesAreConverted() throws {
        var (placer, collected) = timed(longestGap: 100_000)
        try placer.append([1], at: .zero)
        // 44.1 kHz ticks: one second later, at 22,050 samples.
        try placer.append([2], at: CMTime(value: 44_100, timescale: 44_100))
        #expect(collected.samples.count == 22_051)
        #expect(collected.samples.last == 2)
    }

    @Test func aBufferWithoutATimestampFollowsOn() throws {
        var (placer, collected) = timed()
        try placer.append([1, 1], at: at(10))
        try placer.append([2], at: .invalid)
        try placer.append([3], at: at(13))
        let expected: [Float] = [1, 1, 2, 3]
        #expect(collected.samples == expected)
    }

    @Test func aJumpPastTheLongestGapIsDamage() throws {
        var (placer, _) = timed(longestGap: 10)
        try placer.append([1], at: at(0))
        #expect(throws: BeatDetector.DetectionError.self) { try placer.append([2], at: at(100)) }
        #expect(throws: BeatDetector.DetectionError.self) { try placer.append([2], at: CMTime(value: .max, timescale: 1)) }
    }
}

// MARK: - Files with unusual timing

/// Writes `segments` of mono float audio at 44.1 kHz into a QuickTime
/// movie, each at its own presentation time, after a session that starts
/// at zero; a segment that starts later than the last one ended leaves a
/// gap in the file's timestamps.
private func writeMovie(_ segments: [(start: Double, samples: [Float])]) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "amv-timing-\(UUID().uuidString).mov")
    let rate = 44_100.0
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ])
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for segment in segments {
        let chunk = 4_096
        for offset in stride(from: 0, to: segment.samples.count, by: chunk) {
            let values = Array(segment.samples[offset..<min(offset + chunk, segment.samples.count)])
            let time = CMTimeAdd(CMTime(seconds: segment.start, preferredTimescale: 44_100), CMTime(value: CMTimeValue(offset), timescale: 44_100))
            let buffer = try pcmBuffer(values, at: time, sampleRate: rate)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            #expect(input.append(buffer))
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed, "\(String(describing: writer.error))")
    return url
}

/// Clicks every half second from `first`, as `BeatDetectorTests` uses.
func clicks(seconds: Double, first: Double, rate: Double = 44_100) -> [Float] {
    var samples = [Float](repeating: 0, count: Int(seconds * rate))
    var generator = SystemRandomNumberGenerator()
    for time in stride(from: first, to: seconds, by: 0.5) {
        let start = Int(time * rate)
        for index in 0..<Int(0.03 * rate) where start + index < samples.count {
            samples[start + index] = Float.random(in: -1...1, using: &generator) * Float(exp(-Double(index) / (0.006 * rate))) * 0.8
        }
    }
    return samples
}

/// How far each beat is from the nearest of `clicks`.
private func misses(_ track: BeatTrack, clicks: [Double]) -> [Double] {
    track.beats(from: CMTime(seconds: -100, preferredTimescale: 600), to: CMTime(seconds: 1_000, preferredTimescale: 600))
        .map { beat in clicks.map { abs($0 - beat.seconds) }.min() ?? .infinity }
}

@Suite struct BeatTimingTests {
    @Test func audioThatStartsLateKeepsItsBeatsInAssetTime() async throws {
        let url = try await writeMovie([(start: 3, samples: clicks(seconds: 12, first: 0.1))])
        defer { try? FileManager.default.removeItem(at: url) }

        let track = try await BeatDetector.detect(url: url)

        let expected = Array(stride(from: 3.1, to: 15, by: 0.5))
        #expect(!track.isEmpty)
        #expect(misses(track, clicks: expected).allSatisfy { $0 < 0.05 })
        #expect(try #require(track.beats(from: .zero, to: CMTime(seconds: 100, preferredTimescale: 600)).first).seconds > 3)
    }

    @Test func beatsAfterAnEmptyEditStayInAssetTime() async throws {
        // 20 s of clicks with 4.25 s of nothing edited in at 10 s, which
        // puts the clicks after it off the grid of those before.
        let source = try await writeMovie([(start: 0, samples: clicks(seconds: 20, first: 0.1))])
        defer { try? FileManager.default.removeItem(at: source) }
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-gap-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let movie = AVMutableMovie(url: source)
        movie.insertEmptyTimeRange(CMTimeRange(start: CMTime(seconds: 10, preferredTimescale: 600), duration: CMTime(seconds: 4.25, preferredTimescale: 600)))
        try movie.writeHeader(to: url, fileType: .mov, options: .addMovieHeaderToDestination)

        let track = try await BeatDetector.detect(url: url)

        let expected = Array(stride(from: 0.1, to: 10, by: 0.5)) + Array(stride(from: 14.35, to: 24.25, by: 0.5))
        let late = track.beats(from: CMTime(seconds: 15, preferredTimescale: 600), to: CMTime(seconds: 23, preferredTimescale: 600))
        #expect(late.count >= 12)
        for beat in late {
            #expect(expected.contains { abs($0 - beat.seconds) < 0.05 }, "beat at \(beat.seconds)s is off the clicks")
        }
    }

    @Test func beatsAfterADiscontinuityInTheTimestampsStayInAssetTime() throws {
        // Ten seconds of clicks, then a timestamp jump of 4.25 s, then ten
        // more: joined end to end, the second half would be early by the jump.
        let rate = BeatDetector.sampleRate
        let half = clicks(seconds: 10, first: 0.1, rate: rate)
        var buffers: [CMSampleBuffer] = []
        for (start, offset) in [(0.0, 0), (14.25, 0)] {
            for chunk in stride(from: offset, to: half.count, by: 4_096) {
                let values = Array(half[chunk..<min(chunk + 4_096, half.count)])
                let time = CMTime(value: CMTimeValue(start * rate) + CMTimeValue(chunk), timescale: CMTimeScale(rate))
                buffers.append(try pcmBuffer(values, at: time))
            }
        }
        var source = FakeSource(buffers: buffers)

        let track = try BeatDetector.analyze(&source, duration: 24.25, isCancelled: { false }, progress: { _ in })

        let expected = Array(stride(from: 0.1, to: 10, by: 0.5)) + Array(stride(from: 14.35, to: 24.25, by: 0.5))
        let late = track.beats(from: CMTime(seconds: 15, preferredTimescale: 600), to: CMTime(seconds: 23, preferredTimescale: 600))
        #expect(late.count >= 12)
        for beat in late {
            #expect(expected.contains { abs($0 - beat.seconds) < 0.05 }, "beat at \(beat.seconds)s is off the clicks")
        }
    }

    @Test func overlappingBuffersDontDelayTheBeatsAfterThem() throws {
        let rate = BeatDetector.sampleRate
        let audio = clicks(seconds: 16, first: 0.1, rate: rate)
        var buffers: [CMSampleBuffer] = []
        for chunk in stride(from: 0, to: audio.count, by: 4_096) {
            let values = Array(audio[chunk..<min(chunk + 4_096, audio.count)])
            buffers.append(try pcmBuffer(values, at: CMTime(value: CMTimeValue(chunk), timescale: CMTimeScale(rate))))
            // Every eighth buffer is handed out twice, as a repeat would be.
            if (chunk / 4_096) % 8 == 3 { buffers.append(buffers[buffers.count - 1]) }
        }
        var source = FakeSource(buffers: buffers)

        let track = try BeatDetector.analyze(&source, duration: 16, isCancelled: { false }, progress: { _ in })

        #expect(!track.isEmpty)
        #expect(misses(track, clicks: Array(stride(from: 0.1, to: 16, by: 0.5))).allSatisfy { $0 < 0.05 })
    }
}

/// Buffers made up by a test, as if read from a file.
struct FakeSource: DecodedAudioSource {
    var buffers: [CMSampleBuffer]
    /// What `checkCompleted` throws, as a reader that stopped early would.
    var failure: (any Error)?
    /// Called before each buffer is handed out, with how many have been.
    var willHandOut: (Int) -> Void = { _ in }
    private(set) var handedOut = 0
    let cancelled = Flag()

    init(buffers: [CMSampleBuffer], failure: (any Error)? = nil) {
        self.buffers = buffers
        self.failure = failure
    }

    final class Flag: @unchecked Sendable {
        var isSet = false
    }

    mutating func next() -> CMSampleBuffer? {
        willHandOut(handedOut)
        guard handedOut < buffers.count else { return nil }
        handedOut += 1
        return buffers[handedOut - 1]
    }

    func checkCompleted() throws {
        if let failure { throw failure }
    }

    func cancel() { cancelled.isSet = true }
}

// MARK: - Cancellation

/// Twelve seconds of clicks in reader-sized buffers.
private func clickBuffers() throws -> [CMSampleBuffer] {
    let rate = BeatDetector.sampleRate
    let audio = clicks(seconds: 12, first: 0.1, rate: rate)
    return try stride(from: 0, to: audio.count, by: 4_096).map { chunk in
        try pcmBuffer(Array(audio[chunk..<min(chunk + 4_096, audio.count)]), at: CMTime(value: CMTimeValue(chunk), timescale: CMTimeScale(rate)))
    }
}

private final class Switch: @unchecked Sendable {
    var isOn = false
}

@Suite struct BeatCancellationTests {
    @Test func cancellingAtTheEndOfTheAudioIsNotAResult() throws {
        var source = FakeSource(buffers: try clickBuffers())
        let cancelled = Switch()
        let count = source.buffers.count
        // Turns on as the source runs out, after every buffer was read.
        source.willHandOut = { if $0 == count { cancelled.isOn = true } }

        #expect(throws: CancellationError.self) {
            _ = try BeatDetector.analyze(&source, duration: 12, isCancelled: { cancelled.isOn }, progress: { _ in })
        }
        #expect(source.cancelled.isSet)
    }

    @Test func cancellingPartWayStopsReading() throws {
        var source = FakeSource(buffers: try clickBuffers())
        let cancelled = Switch()
        source.willHandOut = { if $0 == 10 { cancelled.isOn = true } }

        #expect(throws: CancellationError.self) {
            _ = try BeatDetector.analyze(&source, duration: 12, isCancelled: { cancelled.isOn }, progress: { _ in })
        }
        // The switch turned on while the eleventh went out; none after it.
        #expect(source.handedOut == 11)
        #expect(source.cancelled.isSet)
    }

    @Test func trackingChecksInAsItGoesAndStopsWhenTold() throws {
        let analyzer = OnsetAnalyzer()
        clicks(seconds: 30, first: 0.1, rate: BeatDetector.sampleRate).withUnsafeBufferPointer { analyzer.append($0) }
        var checks = 0
        _ = try BeatTracker.track(envelope: analyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond) { _ in checks += 1 }
        #expect(checks > 20)

        for stopAt in [1, checks / 2, checks] {
            var seen = 0
            #expect(throws: CancellationError.self, "stopping at check \(stopAt)") {
                _ = try BeatTracker.track(envelope: analyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond) { _ in
                    seen += 1
                    if seen == stopAt { throw CancellationError() }
                }
            }
        }
    }

    @Test func aReadThatStoppedEarlyIsAFailureNotAnEmptyResult() throws {
        // Nothing read and no cancellation asked for: as a reader that was
        // cancelled or failed elsewhere would look.
        var source = FakeSource(buffers: [], failure: BeatDetector.DetectionError.readerFailed("reading stopped before the end"))
        #expect(throws: BeatDetector.DetectionError.self) {
            _ = try BeatDetector.analyze(&source, duration: 12, isCancelled: { false }, progress: { _ in })
        }

        var partial = FakeSource(buffers: Array(try clickBuffers().prefix(20)), failure: BeatDetector.DetectionError.readerFailed("stopped"))
        #expect(throws: BeatDetector.DetectionError.self) {
            _ = try BeatDetector.analyze(&partial, duration: 12, isCancelled: { false }, progress: { _ in })
        }
    }

    @Test func detectingInACancelledTaskThrowsCancellation() async throws {
        let url = try await writeMovie([(start: 0, samples: clicks(seconds: 6, first: 0.1))])
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BeatDetector.detect(url: url)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

// MARK: - Progress

private final class Reports: @unchecked Sendable {
    var values: [Double] = []
}

@Suite struct BeatProgressTests {
    private func isWellFormed(_ values: [Double]) -> Bool {
        values.allSatisfy { $0.isFinite && (0...1).contains($0) } && zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
    }

    @Test func progressRunsThroughTrackingAndEndsAtOneWithTheResult() throws {
        var source = FakeSource(buffers: try clickBuffers())
        let reports = Reports()

        let track = try BeatDetector.analyze(&source, duration: 12, isCancelled: { false }) { reports.values.append($0) }

        #expect(!track.isEmpty)
        #expect(isWellFormed(reports.values))
        #expect(reports.values.last == 1)
        #expect(reports.values.filter { $0 == 1 }.count == 1)
        // Tracking reports in its own share, after reading's.
        #expect(reports.values.contains { $0 > BeatDetector.readingShare && $0 < 1 })
        #expect(reports.values.contains { $0 > 0 && $0 < BeatDetector.readingShare })
    }

    @Test func anEmptyResultAlsoEndsAtOne() throws {
        let silence = try pcmBuffer([Float](repeating: 0, count: 22_050))
        var source = FakeSource(buffers: [silence])
        let reports = Reports()

        let track = try BeatDetector.analyze(&source, duration: 1, isCancelled: { false }) { reports.values.append($0) }

        #expect(track.isEmpty)
        #expect(reports.values.last == 1)
    }

    @Test func cancelledOrFailedWorkNeverReportsCompletion() throws {
        let reports = Reports()
        var cancelledSource = FakeSource(buffers: try clickBuffers())
        let cancelled = Switch()
        let count = cancelledSource.buffers.count
        cancelledSource.willHandOut = { if $0 == count { cancelled.isOn = true } }
        _ = try? BeatDetector.analyze(&cancelledSource, duration: 12, isCancelled: { cancelled.isOn }) { reports.values.append($0) }

        var failedSource = FakeSource(buffers: try clickBuffers(), failure: BeatDetector.DetectionError.readerFailed("stopped"))
        let failedReports = Reports()
        _ = try? BeatDetector.analyze(&failedSource, duration: 12, isCancelled: { false }) { failedReports.values.append($0) }

        #expect(!reports.values.contains(1))
        #expect(!failedReports.values.contains(1))
        #expect(isWellFormed(reports.values))
        #expect(isWellFormed(failedReports.values))
    }

    @Test func oddTimestampsAndDurationsGiveWellFormedProgress() throws {
        let buffers = try clickBuffers()
        // Out of order, missing and far-off timestamps.
        var shuffled = try [pcmBuffer([0], at: CMTime(seconds: 11, preferredTimescale: 600))] + buffers.prefix(30)
        shuffled.append(try pcmBuffer([0], at: .invalid))
        shuffled.append(try pcmBuffer([0], at: CMTime(seconds: -5, preferredTimescale: 600)))
        for duration in [12, 0, -1, .nan, .infinity, 0.001] as [Double] {
            var source = FakeSource(buffers: shuffled)
            let reports = Reports()
            _ = try? BeatDetector.analyze(&source, duration: duration, isCancelled: { false }) { reports.values.append($0) }
            #expect(isWellFormed(reports.values), "duration \(duration): \(reports.values)")
        }
    }
}
