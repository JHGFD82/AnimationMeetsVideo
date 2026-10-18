import AudioToolbox
import CoreMedia
import Foundation

/// The EQ sound effect run on a tap's buffers (see docs/equalizer.md):
/// each band that is on as one or more biquad sections, from the same
/// coefficients the graph draws (`Equalizer`), so what is shown is what
/// is heard.
///
/// The settings are read at a buffer's start and end; when they differ
/// (a keyframed sweep, a drag) the coefficients glide between them every
/// `blockSize` frames instead of jumping once per buffer, which would
/// click.
///
/// Only the tap's own thread touches it after it is made.
final class EqualizerFilter: SoundEffectProcessor {
    let effectID: UUID

    private let sampleRate: Double
    private let channelCount: Int
    private let interleaved: Bool
    private var from = Equalizer.Settings()
    private var to = Equalizer.Settings()
    /// The settings `sections` were made from.
    private var madeFrom: Equalizer.Settings?
    private var sections: [Biquad] = []
    private var outputGain = 1.0
    /// Each section's two state values, per channel: `[channel][section * 2 + k]`.
    private var state: [[Double]]

    /// How often the coefficients move while settings change, in frames.
    static let blockSize = 32

    /// A filter for buffers of 32-bit float samples in `format`. Nil for
    /// any other format.
    init?(effectID: UUID, format: AudioStreamBasicDescription) {
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0, format.mSampleRate > 0
        else { return nil }
        self.effectID = effectID
        sampleRate = format.mSampleRate
        channelCount = Int(format.mChannelsPerFrame)
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        state = Array(repeating: [], count: channelCount)
        sections.reserveCapacity(16)
    }

    func apply(_ effect: Effect, from start: CMTime, to end: CMTime) {
        from = Equalizer.settings(of: effect, at: start)
        to = end == start ? from : Equalizer.settings(of: effect, at: end)
    }

    func reset() {
        for channel in state.indices {
            for index in state[channel].indices { state[channel][index] = 0 }
        }
    }

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0 else { return }
        // Nothing to do while flat throughout; the state is kept, so
        // turning a band back on picks up cleanly.
        if from.isFlat, to.isFlat { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channels: [(UnsafeMutablePointer<Float>, Int)] = []
        if interleaved {
            if let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
                for channel in 0..<channelCount { channels.append((data + channel, channelCount)) }
            }
        } else {
            for buffer in buffers.prefix(channelCount) {
                if let data = buffer.mData?.assumingMemoryBound(to: Float.self) { channels.append((data, 1)) }
            }
        }
        guard !channels.isEmpty else { return }

        let gliding = from != to
        var start = 0
        while start < frames {
            let count = gliding ? min(Self.blockSize, frames - start) : frames - start
            let settings = gliding ? from.interpolated(to: to, fraction: Double(start) / Double(frames)) : to
            if settings != madeFrom { make(settings) }
            for (index, channel) in channels.enumerated() {
                run(channel, from: start, count: count, state: &state[index])
            }
            start += count
        }
        // Tiny leftovers in the state would slow the filters down once the
        // sound stops (denormals) and are inaudible.
        for channel in state.indices {
            for index in state[channel].indices where abs(state[channel][index]) < 1e-20 { state[channel][index] = 0 }
        }
    }

    /// Rebuilds the sections for `settings`, keeping each one's state
    /// where the same sections stay.
    private func make(_ settings: Equalizer.Settings) {
        sections.removeAll(keepingCapacity: true)
        for band in settings.bands {
            Equalizer.appendSections(for: band, sampleRate: sampleRate, to: &sections)
        }
        outputGain = pow(10, settings.output / 20)
        let needed = sections.count * 2
        for channel in state.indices where state[channel].count != needed {
            // Bands switched on or off: the sections no longer line up, so
            // they start from silence.
            state[channel] = Array(repeating: 0, count: needed)
        }
        madeFrom = settings
    }

    /// Filters `count` frames of one channel in place, through every
    /// section (transposed direct form II, in doubles), then the output
    /// gain.
    private func run(_ channel: (UnsafeMutablePointer<Float>, Int), from start: Int, count: Int, state: inout [Double]) {
        let (data, stride) = channel
        let gain = outputGain
        sections.withUnsafeBufferPointer { sections in
            state.withUnsafeMutableBufferPointer { z in
                for frame in start..<(start + count) {
                    var sample = Double(data[frame * stride])
                    for (index, s) in sections.enumerated() {
                        let k = index * 2
                        let output = s.b0 * sample + z[k]
                        z[k] = s.b1 * sample - s.a1 * output + z[k + 1]
                        z[k + 1] = s.b2 * sample - s.a2 * output
                        sample = output
                    }
                    data[frame * stride] = Float(sample * gain)
                }
            }
        }
    }
}
