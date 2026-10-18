import AudioToolbox
import CoreMedia
import Foundation

/// One sound effect of a clip (an EQ, compressor or limiter) as one of
/// Apple's Audio Units, run in place on the buffers of an audio track's tap
/// (`AudioLevelTap`). The tap makes one per effect when it is prepared, sets
/// its parameters from the effect's controls before each buffer, so edits
/// and keyframes are heard as it plays, and throws it away when unprepared.
///
/// Only the tap's own thread touches a unit after it is made.
final class AudioEffectUnit {
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

    /// How many bands the EQ uses: low cut, bass, mid and treble.
    private static let equalizerBands: UInt32 = 4

    /// A unit for `kind` taking `format`, which must be non-interleaved
    /// 32-bit float, in buffers of up to `maxFrames`. Nil when the kind
    /// isn't a sound effect or the unit can't be made.
    init?(effectID: UUID, kind: EffectKind, format: AudioStreamBasicDescription, maxFrames: Int) {
        let subType: OSType
        switch kind {
        case .equalizer: subType = kAudioUnitSubType_NBandEQ
        case .compressor: subType = kAudioUnitSubType_DynamicsProcessor
        case .limiter: subType = kAudioUnitSubType_PeakLimiter
        case .transform, .blending, .color, .matte: return nil
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
        var bands = Self.equalizerBands
        var callback = AURenderCallbackStruct(inputProc: Self.render, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        func size<T>(_: T) -> UInt32 { UInt32(MemoryLayout<T>.size) }
        var status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, size(streamFormat))
        if status == noErr {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &streamFormat, size(streamFormat))
        }
        if status == noErr {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, size(frames))
        }
        if status == noErr, kind == .equalizer {
            status = AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &bands, size(bands))
        }
        if status == noErr {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, size(callback))
        }
        if status == noErr { status = AudioUnitInitialize(unit) }
        // Everything is set by now, so failing runs `deinit`, which lets go
        // of the unit and the buffers.
        guard status == noErr else { return nil }
        if kind == .equalizer { setUpEqualizer() }
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

    /// Forgets the sound it has heard, after a jump in time, so the
    /// compressor's envelope and the filters' state don't carry over.
    func reset() {
        AudioUnitReset(unit, kAudioUnitScope_Global, 0)
    }

    // MARK: Parameters

    /// The bands' fixed parts: a high-pass for the low cut, shelves for
    /// bass and treble, and a peak for the mid.
    private func setUpEqualizer() {
        let types: [Int] = [
            kAUNBandEQFilterType_2ndOrderButterworthHighPass, kAUNBandEQFilterType_LowShelf,
            kAUNBandEQFilterType_Parametric, kAUNBandEQFilterType_HighShelf,
        ]
        for (band, type) in types.enumerated() {
            set(kAUNBandEQParam_FilterType + UInt32(band), Float(type))
            set(kAUNBandEQParam_BypassBand + UInt32(band), 0)
        }
        set(kAUNBandEQParam_Frequency + 1, 100)
        set(kAUNBandEQParam_Bandwidth + 2, 1)
        set(kAUNBandEQParam_Frequency + 3, 8000)
    }

    private func set(_ parameter: AudioUnitParameterID, _ value: Float) {
        AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0)
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
        case .equalizer:
            // At its lowest the low cut is off rather than cutting below
            // what can be heard anyway.
            let lowCut = value(.lowCut)
            set(kAUNBandEQParam_BypassBand, lowCut <= Float(ControlKind.lowCut.range!.lowerBound) ? 1 : 0)
            set(kAUNBandEQParam_Frequency, lowCut)
            set(kAUNBandEQParam_Gain + 1, value(.bass))
            set(kAUNBandEQParam_Frequency + 2, value(.midFrequency))
            set(kAUNBandEQParam_Gain + 2, value(.mid))
            set(kAUNBandEQParam_Gain + 3, value(.treble))
        case .compressor:
            set(kDynamicsProcessorParam_Threshold, value(.threshold))
            set(kDynamicsProcessorParam_HeadRoom, value(.headroom))
            set(kDynamicsProcessorParam_AttackTime, value(.attack) / 1000)
            set(kDynamicsProcessorParam_ReleaseTime, value(.release) / 1000)
            set(kDynamicsProcessorParam_OverallGain, value(.makeup))
        case .limiter:
            set(kLimiterParam_PreGain, value(.drive))
            set(kLimiterParam_DecayTime, value(.limiterRelease) / 1000)
        case .transform, .blending, .color, .matte:
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
