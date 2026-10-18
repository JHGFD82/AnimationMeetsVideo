import AudioToolbox
import CoreMedia
import Foundation
import os

/// Writes a take to a CAF file as its sound arrives, from whatever thread
/// the capture calls back on, and works out where on the timeline its
/// first sample belongs.
final class TakeWriter: @unchecked Sendable {
    let url: URL
    let format: AudioStreamBasicDescription
    private let file: ExtAudioFileRef
    /// Given a buffer's host time, the timeline time of its first sample,
    /// or nil while that can't be told yet (the timeline hasn't started
    /// moving). Asked of each buffer until it answers.
    private let anchor: @Sendable (UInt64) -> CMTime?

    private struct State {
        var frames: Int64 = 0
        var start: CMTime?
        var peak: Float = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(url: URL, format: AudioStreamBasicDescription, anchor: @escaping @Sendable (UInt64) -> CMTime?) throws {
        self.url = url
        self.format = format
        self.anchor = anchor
        // Kept as 32-bit float, interleaved: files can't hold channels
        // apart. ExtAudioFile converts from whatever comes in.
        let channels = max(1, format.mChannelsPerFrame)
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        )
        var made: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &made)
        guard status == noErr, let made else { throw RecordingError.cantWrite(status) }
        var client = format
        status = ExtAudioFileSetProperty(made, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else {
            ExtAudioFileDispose(made)
            throw RecordingError.cantWrite(status)
        }
        // Readies the asynchronous writer off the capture's thread.
        ExtAudioFileWriteAsync(made, 0, nil)
        file = made
    }

    /// Writes `frames` frames that arrived at `hostTime`.
    func write(_ list: UnsafePointer<AudioBufferList>, frames: UInt32, hostTime: UInt64) {
        guard frames > 0 else { return }
        ExtAudioFileWriteAsync(file, frames, list)
        var peak: Float = 0
        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for index in 0..<Int(buffer.mDataByteSize) / 4 { peak = max(peak, abs(data[index])) }
            }
        }
        let rate = format.mSampleRate
        let loudest = peak
        let needsStart = state.withLock { $0.start == nil }
        // Asked outside the lock: it reads the player's clock.
        let placed = needsStart ? anchor(hostTime) : nil
        state.withLock { state in
            if state.start == nil, let placed, rate > 0 {
                // Back to the take's first sample.
                state.start = CMTimeSubtract(placed, CMTime(seconds: Double(state.frames) / rate, preferredTimescale: 96_000))
            }
            state.frames += Int64(frames)
            state.peak = max(state.peak, loudest)
        }
    }

    /// How long the take is so far, in seconds.
    var seconds: Double {
        let frames = state.withLock { $0.frames }
        return format.mSampleRate > 0 ? Double(frames) / format.mSampleRate : 0
    }

    /// The loudest sample since the last call, for a level meter.
    func takePeak() -> Float {
        state.withLock { state in
            defer { state.peak = 0 }
            return state.peak
        }
    }

    /// Where on the timeline the take's first sample belongs, once known.
    var start: CMTime? { state.withLock { $0.start } }

    /// Finishes the file. Nothing more may be written.
    func finish() {
        ExtAudioFileDispose(file)
    }
}

enum RecordingError: LocalizedError {
    case cantWrite(OSStatus)
    case noInput
    case microphoneDenied
    case cantTap(OSStatus)
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .cantWrite(let status): "The recording couldn't be written (error \(status))."
        case .noInput: "There is no input device to record from."
        case .microphoneDenied:
            "Animation Meets Video isn't allowed to record from the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        case .cantTap(let status): "That app's sound couldn't be recorded (error \(status))."
        case .nothingRecorded: "Nothing was recorded."
        }
    }
}
