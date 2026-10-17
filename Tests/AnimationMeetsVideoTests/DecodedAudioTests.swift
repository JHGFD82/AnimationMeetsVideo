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
