import AVFoundation
import CoreMedia
import Foundation
import MediaToolbox
import os

/// One volume and pan a composition audio track plays through: a clip's
/// own (which count in the clip's source time) or a Sound or Music layer's
/// (which count in its timeline's time), then those of the clips and
/// layers of the timelines it is nested in.
struct MixStage: Equatable, Sendable {
    /// The ID of the clip or the layer.
    let id: UUID
    /// Root time minus the time the stage's keyframes count in, when they
    /// count at the root's pace.
    let shift: CMTime
    /// How much faster the keyframes' time passes than the root's: a retimed
    /// clip's volume counts in its source time, which plays at its speed.
    var rate: Double = 1
    /// Set for a stage that is a fade under a transition rather than the
    /// clip's or layer's own volume and pan.
    var fade: AudioFade?

    /// The stage's own time at root time `time`.
    func local(_ time: CMTime) -> CMTime {
        let local = CMTimeSubtract(time, shift)
        return rate == 1 ? local : CMTimeMultiplyByFloat64(local, multiplier: rate)
    }
}

/// Every clip's and layer's volume and pan curves, and every clip's sound
/// effects, shared between the editor and the audio taps playing it. The
/// editor swaps in new ones as they are edited; the taps read whichever set
/// is current as each buffer plays, so a change is heard at once without
/// rebuilding the player.
final class MixCurves: @unchecked Sendable {
    /// Curves by clip or layer ID. Only those that aren't at their default
    /// throughout (0 dB, centered) are kept.
    struct Curves: Equatable, Sendable {
        var volume: [UUID: AnimatedValue<Double>] = [:]
        var pan: [UUID: AnimatedValue<Double>] = [:]
        /// The enabled sound effects of each clip that has any, in order.
        var effects: [UUID: [Effect]] = [:]
    }

    private let curves = OSAllocatedUnfairLock(initialState: Curves())

    init(_ curves: Curves = Curves()) {
        self.curves.withLock { $0 = curves }
    }

    convenience init(volume: [UUID: AnimatedValue<Double>], pan: [UUID: AnimatedValue<Double>] = [:]) {
        self.init(Curves(volume: volume, pan: pan))
    }

    var current: Curves { curves.withLock { $0 } }

    /// The curves of every clip and Sound or Music layer of `project`.
    static func of(_ project: EditingProject) -> Curves {
        var curves = Curves()
        let flat = AnimatedValue(0.0)
        for timeline in project.timelines {
            for layer in timeline.layers {
                if layer.kind.isAudio {
                    if layer.volume != flat { curves.volume[layer.id] = layer.volume }
                    if layer.pan != flat { curves.pan[layer.id] = layer.pan }
                    let effects = layer.audioEffects.filter(\.enabled)
                    if !effects.isEmpty { curves.effects[layer.id] = effects }
                }
                for clip in layer.clips {
                    if clip.volume != flat { curves.volume[clip.id] = clip.volume }
                    if clip.pan != flat { curves.pan[clip.id] = clip.pan }
                    let effects = clip.audioEffects.filter(\.enabled)
                    if !effects.isEmpty { curves.effects[clip.id] = effects }
                }
            }
        }
        return curves
    }

    func replace(with new: Curves) {
        curves.withLock { $0 = new }
    }

    /// The gain of a track playing through `stages` at root time `seconds`,
    /// from their volumes alone.
    func gain(through stages: [MixStage], at seconds: Double) -> Float {
        gains(through: stages, at: seconds, panned: false).x
    }

    /// The left and right gains of a track playing through `stages` at root
    /// time `seconds`: their volumes, and their pans one after another.
    func gains(through stages: [MixStage], at seconds: Double) -> SIMD2<Float> {
        gains(through: stages, at: seconds, panned: true)
    }

    private func gains(through stages: [MixStage], at seconds: Double, panned: Bool) -> SIMD2<Float> {
        guard !stages.isEmpty else { return SIMD2(1, 1) }
        let current = curves.withLock { $0 }
        let time = CMTime(seconds: seconds, preferredTimescale: 96_000)
        var gains = SIMD2<Float>(1, 1)
        for stage in stages {
            if let fade = stage.fade {
                gains *= fade.gain(at: seconds)
                continue
            }
            let volume = current.volume[stage.id], pan = panned ? current.pan[stage.id] : nil
            guard volume != nil || pan != nil else { continue }
            let local = stage.local(time)
            if let volume { gains *= AudioLevel.gain(decibels: volume.value(at: local)) }
            if let pan { gains *= AudioPan.gains(pan.value(at: local)) }
        }
        return gains
    }
}

/// Applies sound effects, volumes and pans to one composition audio track
/// as it plays or exports, and reports what it lets through to a
/// `MixLevelMeter`.
enum AudioLevelTap {
    /// An audio mix with a tap on each of `tracks`.
    static func audioMix(
        for tracks: [ComposedAudioTrack],
        curves: MixCurves,
        meter: MixLevelMeter?
    ) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.enumerated().compactMap { index, entry in
            let parameters = AVMutableAudioMixInputParameters(track: entry.track)
            // How retimed sound is played: at the new speed at its own pitch
            // (spectral), or like tape (varispeed).
            if let pitch = entry.pitch { parameters.audioTimePitchAlgorithm = pitch }
            // Which effects the track plays through is fixed when the mix
            // is made (a change to it changes `CompositionKey`, which makes
            // a new one); their settings are read as it plays.
            let current = curves.current
            let effects = entry.stages.enumerated().flatMap { stage, entry in
                entry.fade != nil ? [] : (current.effects[entry.id] ?? []).map { (stage: stage, id: $0.id, kind: $0.kind) }
            }
            let context = TapContext(
                stages: entry.stages, effects: effects, latency: entry.latency, curves: curves, meter: meter, meterIndex: index
            )
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
            prepare: { tap, maxFrames, format in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .prepare(format: format.pointee, maxFrames: Int(maxFrames))
            },
            unprepare: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().unprepare()
            },
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
        let stages: [MixStage]
        /// The sound effects the track plays through, innermost stage
        /// first, each with the index of the stage it belongs to.
        let effects: [(stage: Int, id: UUID, kind: EffectKind)]
        /// How far ahead of when it is heard the track's sound reaches the
        /// tap, in seconds; its curves and the meter go by when it is heard.
        let latency: Double
        let curves: MixCurves
        let meter: MixLevelMeter?
        let meterIndex: Int
        var format = AudioStreamBasicDescription()
        /// The effects as filters or Audio Units, made once the format is
        /// known.
        private var units: [(stage: Int, unit: SoundEffectProcessor)] = []
        /// Where the next buffer starts if playing carries straight on, in
        /// seconds; anything further off is a jump, which resets the units.
        private var expectedStart: Double?
        /// How far off a buffer's start may be and still carry straight on.
        /// A player stamps its buffers loosely, a few milliseconds either way
        /// of where the last one ended, though the sound runs on unbroken;
        /// resetting on that silenced voice isolation, which needs 76 ms of
        /// sound before it says anything. A seek, even by one frame, is
        /// further.
        static let jumpTolerance = 0.02
        /// The left and right K-weighting filters for the meter's loudness,
        /// and each frame's weighted squares, made once the format is known.
        private var weighting: [KWeighting] = []
        private var weighted: UnsafeMutablePointer<Float>?
        private var weightedCapacity = 0

        init(
            stages: [MixStage], effects: [(stage: Int, id: UUID, kind: EffectKind)], latency: Double,
            curves: MixCurves, meter: MixLevelMeter?, meterIndex: Int
        ) {
            self.stages = stages
            self.effects = effects
            self.latency = latency
            self.curves = curves
            self.meter = meter
            self.meterIndex = meterIndex
        }

        func prepare(format: AudioStreamBasicDescription, maxFrames: Int) {
            self.format = format
            // An effect whose unit can't be made, or a format the units
            // can't take, plays the sound without it.
            units = effects.compactMap { effect in
                SoundEffects.processor(effectID: effect.id, kind: effect.kind, format: format, maxFrames: maxFrames).map { (effect.stage, $0) }
            }
            expectedStart = nil
            if meter != nil, maxFrames > 0 {
                weighting = Array(repeating: KWeighting(sampleRate: format.mSampleRate), count: 2)
                weighted?.deallocate()
                weighted = .allocate(capacity: maxFrames)
                weightedCapacity = maxFrames
            }
        }

        func unprepare() {
            units = []
            weighted?.deallocate()
            weighted = nil
            weightedCapacity = 0
        }

        deinit {
            weighted?.deallocate()
        }

        /// Each frame's K-weighted squares summed over left and right, for
        /// the meter's loudness. A single channel plays on both sides, so
        /// it counts twice.
        private func weigh(_ channels: [(UnsafeMutablePointer<Float>, Int)], frames: Int) -> UnsafePointer<Float>? {
            guard let weighted, frames <= weightedCapacity, weighting.count == 2 else { return nil }
            let stereo = channels.count > 1
            for frame in 0..<frames {
                let left = weighting[0](channels[0].0[frame * channels[0].1])
                if stereo {
                    let right = weighting[1](channels[1].0[frame * channels[1].1])
                    weighted[frame] = left * left + right * right
                } else {
                    weighted[frame] = 2 * left * left
                }
            }
            return UnsafePointer(weighted)
        }

        /// Runs the buffer through the sound effects of stage `stage`, each
        /// set as its controls are over the buffer.
        private func applyEffects(
            ofStage stage: Int, _ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int,
            heard: CMTime, current: MixCurves.Curves
        ) {
            let owner = stages[stage]
            let end = CMTimeAdd(heard, CMTime(seconds: Double(frames) / format.mSampleRate, preferredTimescale: 96_000))
            for (index, unit) in units where index == stage {
                // An effect switched off or deleted since the mix was made
                // is left out until the player is rebuilt.
                guard let effect = current.effects[owner.id]?.first(id: unit.effectID) else { continue }
                unit.apply(effect, from: owner.local(heard), to: owner.local(end))
                unit.process(bufferList, frames: frames)
            }
        }

        /// Multiplies the channels by gains ramping from `first` to `last`
        /// over the buffer. The first channel is left and the second right.
        /// A pan keeps the nearer side as it is, so the louder of the two
        /// gains is the volume (less any pans that pull opposite ways): what
        /// a single channel, which can't be panned, and any channels past
        /// the second get.
        private func applyGains(_ first: SIMD2<Float>, _ last: SIMD2<Float>, to channels: [(UnsafeMutablePointer<Float>, Int)], frames: Int) {
            guard first != SIMD2(1, 1) || last != SIMD2(1, 1) else { return }
            let stereo = channels.count > 1
            for (index, (data, stride)) in channels.enumerated() {
                let (from, to): (Float, Float) = switch index {
                case 0 where stereo: (first.x, last.x)
                case 1: (first.y, last.y)
                default: (first.max(), last.max())
                }
                var gain = from
                let step = frames > 1 ? (to - from) / Float(frames - 1) : 0
                for frame in 0..<frames {
                    data[frame * stride] *= gain
                    gain += step
                }
            }
        }

        func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: CMTime) {
            // Only float samples, which is what players and export sessions
            // hand taps; anything else passes through untouched.
            guard frames > 0, start.isNumeric, format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
                  format.mSampleRate > 0
            else { return }
            // A jump in time (a seek, a loop) starts the effects and the
            // loudness filters afresh.
            if let expected = expectedStart, abs(start.seconds - expected) > Self.jumpTolerance {
                for index in weighting.indices { weighting[index].reset() }
                for (_, unit) in units { unit.reset() }
            }
            // When the sound is heard, once its effects' delay puts it back.
            let heard = CMTimeAdd(start, CMTime(seconds: latency, preferredTimescale: 96_000))
            expectedStart = start.seconds + Double(frames) / format.mSampleRate
            let rate = format.mSampleRate
            let startSeconds = heard.seconds
            let endSeconds = startSeconds + Double(frames) / rate

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

            if units.isEmpty {
                applyGains(
                    curves.gains(through: stages, at: startSeconds), curves.gains(through: stages, at: endSeconds),
                    to: channels, frames: frames
                )
            } else {
                // Stage by stage, as a channel strip: a clip's effects, then
                // its volume and pan, then its layer's effects, then the
                // layer's volume and pan, and so on outward. Gains between
                // effects are gathered and applied together.
                let current = curves.current
                var first = SIMD2<Float>(1, 1), last = SIMD2<Float>(1, 1)
                for index in stages.indices {
                    if units.contains(where: { $0.stage == index }) {
                        applyGains(first, last, to: channels, frames: frames)
                        first = SIMD2(1, 1)
                        last = SIMD2(1, 1)
                        applyEffects(ofStage: index, bufferList, frames: frames, heard: heard, current: current)
                    }
                    first *= curves.gains(through: [stages[index]], at: startSeconds)
                    last *= curves.gains(through: [stages[index]], at: endSeconds)
                }
                applyGains(first, last, to: channels, frames: frames)
            }
            meter?.record(
                left: channels[0], right: channels.count > 1 ? channels[1] : channels[0],
                weighted: weigh(channels, frames: frames),
                frames: frames, sampleRate: rate, start: startSeconds, track: meterIndex
            )
        }
    }
}
