import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import os

/// One sound effect of a clip as a tap (`AudioLevelTap`) runs it: made
/// when the tap is prepared, set from the effect's controls before each
/// buffer, so edits and keyframes are heard as it plays, and thrown away
/// when unprepared.
protocol SoundEffectProcessor: AnyObject {
    var effectID: UUID { get }
    /// Sets it from `effect`'s controls for a buffer that plays from
    /// `start` to `end`, in the clip's source time.
    func apply(_ effect: Effect, from start: CMTime, to end: CMTime)
    /// Runs `frames` frames of `buffers` through it, in place.
    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int)
    /// Forgets the sound it has heard, after a jump in time.
    func reset()
}

enum SoundEffects {
    /// What runs an effect of `kind` on buffers in `format` of up to
    /// `maxFrames`: the EQ's own filters, or one of Apple's Audio Units.
    /// Nil for a picture effect, or when it can't be made.
    static func processor(effectID: UUID, kind: EffectKind, format: AudioStreamBasicDescription, maxFrames: Int) -> SoundEffectProcessor? {
        if kind == .equalizer { return EqualizerFilter(effectID: effectID, format: format, maxFrames: maxFrames) }
        return AudioEffectUnit(effectID: effectID, kind: kind, format: format, maxFrames: maxFrames)
    }
}

/// One sound effect of a clip (a compressor, limiter or voice isolation) as
/// one of Apple's Audio Units, run in place on the buffers of an audio
/// track's tap (`AudioLevelTap`). The EQ has filters of its own
/// (`EqualizerFilter`).
///
/// Only the tap's own thread touches a unit after it is made.
final class AudioEffectUnit: SoundEffectProcessor {
    let effectID: UUID
    let kind: EffectKind

    private let unit: AudioUnit
    private let channelCount: Int
    private let maxFrames: Int
    /// Where the unit writes, since it can't safely write where it reads.
    private let output: UnsafeMutableAudioBufferListPointer
    /// What the render callback hands the unit: the tap's buffers, set for
    /// the length of one `process` call.
    private var source: UnsafeMutableAudioBufferListPointer?
    private var sampleTime: Float64 = 0

    /// A unit for `kind` taking `format`, which must be non-interleaved
    /// 32-bit float, in buffers of up to `maxFrames`. Nil when the kind
    /// isn't a sound effect or the unit can't be made.
    init?(effectID: UUID, kind: EffectKind, format: AudioStreamBasicDescription, maxFrames: Int) {
        let subType: OSType
        switch kind {
        case .compressor: subType = kAudioUnitSubType_DynamicsProcessor
        case .limiter: subType = kAudioUnitSubType_PeakLimiter
        case .voiceIsolation: subType = kAudioUnitSubType_AUSoundIsolation
        case .equalizer, .transform, .blending, .color, .matte, .rectangle, .ellipse, .polygon, .star, .stroke,
             .audioKeys, .beatKeys, .wiggler, .oscillator, .smoother, .looper, .timeStep, .overshoot,
             .hueCycle, .cosinePalette, .gradientMap, .solarize, .posterize, .channelMixer, .falseColor, .neonEdges,
             .grain, .staticNoise, .fractalNoise, .cells, .dither, .interference, .blockGlitch,
             .displace, .liquid, .twirl, .wave, .kaleidoscope, .mirrorTile, .chromaticAberration: return nil
        }
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0, format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0, maxFrames > 0
        else { return nil }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        var made: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &made) == noErr, let made
        else { return nil }

        self.effectID = effectID
        self.kind = kind
        unit = made
        channelCount = Int(format.mChannelsPerFrame)
        self.maxFrames = maxFrames
        output = AudioBufferList.allocate(maximumBuffers: channelCount)
        for index in 0..<channelCount {
            output[index] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(maxFrames * 4),
                mData: UnsafeMutableRawPointer.allocate(byteCount: maxFrames * 4, alignment: 16)
            )
        }

        var streamFormat = format
        var frames = UInt32(maxFrames)
        var callback = AURenderCallbackStruct(inputProc: Self.render, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        func size<T>(_: T) -> UInt32 { UInt32(MemoryLayout<T>.size) }
        var status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, size(streamFormat))
        if status == noErr {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &streamFormat, size(streamFormat))
        }
        if status == noErr {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, size(frames))
        }
        if status == noErr {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, size(callback))
        }
        if status == noErr { status = AudioUnitInitialize(unit) }
        // Everything is set by now, so failing runs `deinit`, which lets go
        // of the unit and the buffers.
        guard status == noErr else { return nil }
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        Self.free(output)
    }

    private static func free(_ list: UnsafeMutableAudioBufferListPointer) {
        for buffer in list { buffer.mData?.deallocate() }
        list.unsafeMutablePointer.deallocate()
    }

    /// How long the unit holds sound back, in seconds: the compressor and
    /// limiter look ahead.
    var latency: Double {
        var seconds: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size)
        return seconds
    }

    /// How long a unit of `kind` holds sound back, in seconds, measured
    /// once from one made at 48 kHz, for working out before any tap is
    /// prepared how much earlier its sound must start. 0 for picture
    /// effects and the EQ, whose filters don't look ahead.
    static func latency(of kind: EffectKind) -> Double {
        latencies.withLock { known in
            if let latency = known[kind] { return latency }
            var latency = 0.0
            if kind.isAudio, let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
               let unit = AudioEffectUnit(effectID: UUID(), kind: kind, format: format.streamDescription.pointee, maxFrames: 4096) {
                latency = unit.latency
            }
            known[kind] = latency
            return latency
        }
    }

    private static let latencies = OSAllocatedUnfairLock(initialState: [EffectKind: Double]())

    /// Forgets the sound it has heard, after a jump in time, so the
    /// compressor's envelope and the filters' state don't carry over.
    func reset() {
        AudioUnitReset(unit, kAudioUnitScope_Global, 0)
    }

    // MARK: Parameters

    private func set(_ parameter: AudioUnitParameterID, _ value: Float) {
        AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0)
    }

    /// Sets the unit's parameters from `effect`'s controls at the buffer's
    /// start: Audio Unit parameters hold for a whole buffer.
    func apply(_ effect: Effect, from start: CMTime, to end: CMTime) {
        apply(effect, at: start)
    }

    /// Sets the unit's parameters from `effect`'s controls at `time`, in
    /// the clip's source time. A control that is off or deleted counts as
    /// at its default.
    func apply(_ effect: Effect, at time: CMTime) {
        func value(_ kind: ControlKind) -> Float {
            let control = effect.control(kind).flatMap { $0.enabled ? $0 : nil }
            let shown = control?.values(at: time).first ?? kind.defaultValues[0]
            return Float(kind.clamped(shown))
        }
        switch kind {
        case .compressor:
            set(kDynamicsProcessorParam_Threshold, value(.threshold))
            set(kDynamicsProcessorParam_HeadRoom, value(.headroom))
            set(kDynamicsProcessorParam_AttackTime, value(.attack) / 1000)
            set(kDynamicsProcessorParam_ReleaseTime, value(.release) / 1000)
            set(kDynamicsProcessorParam_OverallGain, value(.makeup))
        case .limiter:
            set(kLimiterParam_PreGain, value(.drive))
            set(kLimiterParam_DecayTime, value(.limiterRelease) / 1000)
        case .voiceIsolation:
            set(kAUSoundIsolationParam_WetDryMixPercent, value(.isolation))
        case .equalizer, .transform, .blending, .color, .matte, .rectangle, .ellipse, .polygon, .star, .stroke,
             .audioKeys, .beatKeys, .wiggler, .oscillator, .smoother, .looper, .timeStep, .overshoot,
             .hueCycle, .cosinePalette, .gradientMap, .solarize, .posterize, .channelMixer, .falseColor, .neonEdges,
             .grain, .staticNoise, .fractalNoise, .cells, .dither, .interference, .blockGlitch,
             .displace, .liquid, .twirl, .wave, .kaleidoscope, .mirrorTile, .chromaticAberration:
            break
        }
    }

    // MARK: Rendering

    /// Runs `frames` frames of `buffers` (non-interleaved, one buffer per
    /// channel, as the unit was made for) through the unit, in place.
    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        guard frames > 0, frames <= maxFrames, list.count == channelCount else { return }
        source = list
        defer { source = nil }
        for index in 0..<channelCount { output[index].mDataByteSize = UInt32(frames * 4) }
        var flags = AudioUnitRenderActionFlags()
        var timeStamp = AudioTimeStamp()
        timeStamp.mSampleTime = sampleTime
        timeStamp.mFlags = .sampleTimeValid
        sampleTime += Float64(frames)
        guard AudioUnitRender(unit, &flags, &timeStamp, 0, UInt32(frames), output.unsafeMutablePointer) == noErr else { return }
        for index in 0..<channelCount {
            guard let from = output[index].mData, let to = list[index].mData else { continue }
            to.copyMemory(from: from, byteCount: frames * 4)
        }
    }

    /// Hands the unit the tap's samples as its input.
    private static let render: AURenderCallback = { refCon, _, _, _, frames, ioData in
        let host = Unmanaged<AudioEffectUnit>.fromOpaque(refCon).takeUnretainedValue()
        guard let source = host.source, let ioData else { return kAudioUnitErr_NoConnection }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        let bytes = Int(frames) * 4
        for index in 0..<min(list.count, source.count) {
            guard let from = source[index].mData else { continue }
            if let to = list[index].mData {
                to.copyMemory(from: from, byteCount: bytes)
            } else {
                list[index].mData = from
            }
            list[index].mDataByteSize = UInt32(bytes)
        }
        return noErr
    }
}
