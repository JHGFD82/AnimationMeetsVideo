import AVFoundation
import CoreMedia
import Foundation
import MediaToolbox
import os

/// One layer whose volume a composition audio track plays through: the
/// layer itself, then each layer of the timelines it is nested in.
struct VolumeStage: Equatable, Sendable {
    let layerID: UUID
    /// Root time minus this layer's timeline time.
    let shift: CMTime
}

/// Every layer's volume curve, shared between the editor and the audio
/// taps playing it. The editor swaps in new curves as volumes are edited;
/// the taps read whichever set is current as each buffer plays, so a change
/// is heard at once without rebuilding the player.
final class VolumeCurves: @unchecked Sendable {
    private let curves = OSAllocatedUnfairLock(initialState: [UUID: AnimatedValue<Double>]())

    init(_ curves: [UUID: AnimatedValue<Double>] = [:]) {
        self.curves.withLock { $0 = curves }
    }

    /// The curves of every layer of `project` that isn't at 0 dB throughout.
    static func of(_ project: EditingProject) -> [UUID: AnimatedValue<Double>] {
        var curves: [UUID: AnimatedValue<Double>] = [:]
        for timeline in project.timelines {
            for layer in timeline.layers where layer.volume != AnimatedValue(0.0) {
                curves[layer.id] = layer.volume
            }
        }
        return curves
    }

    func replace(with new: [UUID: AnimatedValue<Double>]) {
        curves.withLock { $0 = new }
    }

    /// The gain of a track playing through `stages` at root time `seconds`.
    func gain(through stages: [VolumeStage], at seconds: Double) -> Float {
        guard !stages.isEmpty else { return 1 }
        let current = curves.withLock { $0 }
        let time = CMTime(seconds: seconds, preferredTimescale: 96_000)
        var gain: Float = 1
        for stage in stages {
            guard let curve = current[stage.layerID] else { continue }
            gain *= AudioLevel.gain(decibels: curve.value(at: CMTimeSubtract(time, stage.shift)))
        }
        return gain
    }
}

/// Applies layer volumes to one composition audio track as it plays or
/// exports, and reports what it lets through to a `MixLevelMeter`.
enum AudioLevelTap {
    /// An audio mix with a tap on each of `tracks`.
    static func audioMix(
        for tracks: [(track: AVAssetTrack, stages: [VolumeStage])],
        curves: VolumeCurves,
        meter: MixLevelMeter?
    ) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.enumerated().compactMap { index, entry in
            let parameters = AVMutableAudioMixInputParameters(track: entry.track)
            let context = TapContext(stages: entry.stages, curves: curves, meter: meter, meterIndex: index)
            guard let tap = makeTap(context) else { return nil }
            parameters.audioTapProcessor = tap
            return parameters
        }
        return mix
    }

    private static func makeTap(_ context: TapContext) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().format = format.pointee
            },
            unprepare: nil,
            process: { tap, frameCount, _, bufferList, frameCountOut, flagsOut in
                var timeRange = CMTimeRange()
                guard MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, &timeRange, frameCountOut) == noErr else {
                    return
                }
                let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.process(bufferList, frames: Int(frameCountOut.pointee), start: timeRange.start)
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<TapContext>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        return tap
    }

    /// What one tap knows. Only its tap's own thread touches it after
    /// `prepare`.
    private final class TapContext: @unchecked Sendable {
        let stages: [VolumeStage]
        let curves: VolumeCurves
        let meter: MixLevelMeter?
        let meterIndex: Int
        var format = AudioStreamBasicDescription()

        init(stages: [VolumeStage], curves: VolumeCurves, meter: MixLevelMeter?, meterIndex: Int) {
            self.stages = stages
            self.curves = curves
            self.meter = meter
            self.meterIndex = meterIndex
        }

        func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: CMTime) {
            // Only float samples, which is what players and export sessions
            // hand taps; anything else passes through untouched.
            guard frames > 0, start.isNumeric, format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
                  format.mSampleRate > 0
            else { return }
            let rate = format.mSampleRate
            let startSeconds = start.seconds
            let first = curves.gain(through: stages, at: startSeconds)
            let last = curves.gain(through: stages, at: startSeconds + Double(frames) / rate)

            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            // Up to two channels, as (samples, stride).
            var channels: [(UnsafeMutablePointer<Float>, Int)] = []
            if interleaved {
                let count = Int(max(1, format.mChannelsPerFrame))
                if let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
                    for channel in 0..<count { channels.append((data + channel, count)) }
                }
            } else {
                for buffer in buffers {
                    if let data = buffer.mData?.assumingMemoryBound(to: Float.self) { channels.append((data, 1)) }
                }
            }
            guard !channels.isEmpty else { return }

            if first != 1 || last != 1 {
                let step = frames > 1 ? (last - first) / Float(frames - 1) : 0
                for (data, stride) in channels {
                    var gain = first
                    for frame in 0..<frames {
                        data[frame * stride] *= gain
                        gain += step
                    }
                }
            }
            meter?.record(
                left: channels[0], right: channels.count > 1 ? channels[1] : channels[0],
                frames: frames, sampleRate: rate, start: startSeconds, track: meterIndex
            )
        }
    }
}
