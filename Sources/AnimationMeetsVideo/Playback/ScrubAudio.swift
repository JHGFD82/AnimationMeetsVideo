import AVFoundation
import CoreMedia
import Foundation
import os

/// Plays a short grain of the mix wherever the playhead is moved while
/// paused, so a cut or a beat can be found by ear as well as by eye. See
/// docs/audio.md, "Scrubbing".
///
/// The mix around the playhead is read out through the composition's audio
/// mix, as playback hears it, a few seconds at a time, and kept; grains come
/// from that. Everything (reading, the engine, scheduling) happens on one
/// serial queue, and a request that a newer one has overtaken is dropped,
/// so a fast drag plays only where the playhead is now.
final class ScrubAudio: @unchecked Sendable {
    /// How much of the mix is read at once: a little before the playhead
    /// and more after, since scrubbing mostly moves forward.
    static let before = 1.0
    static let after = 3.0
    /// One grain: long enough to tell what it is, short enough to follow a
    /// drag.
    static let grain = 0.08
    /// Each end of a grain fades over this, so it doesn't click.
    static let fade = 0.005
    static let sampleRate = 48_000.0

    private let queue = DispatchQueue(label: "AnimationMeetsVideo.scrub-audio", qos: .userInitiated)
    /// Requests by number; a job whose number isn't the newest is dropped.
    private let latest = OSAllocatedUnfairLock(initialState: 0)

    // Touched only on `queue`.
    private var composed: ComposedTimeline?
    private var curves: MixCurves?
    private var cache: (start: Double, left: [Float], right: [Float])?
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var deviceUID: String?

    /// Takes up a new composition to read from, forgetting what was read
    /// of the old one.
    func setComposition(_ composed: ComposedTimeline?, curves: MixCurves) {
        let handed = HandedOver(value: composed)
        queue.async {
            self.composed = handed.value
            self.curves = curves
            self.cache = nil
        }
    }

    /// Forgets what was read, after an edit changed what the mix sounds
    /// like.
    func forget() {
        queue.async { self.cache = nil }
    }

    /// Plays the grain at `seconds` of the timeline, out of the device
    /// with `deviceUID` (nil for the system's default).
    func play(at seconds: Double, deviceUID: String?) {
        guard seconds.isFinite else { return }
        let number = latest.withLock { value in
            value += 1
            return value
        }
        queue.async {
            guard self.latest.withLock({ $0 }) == number else { return }
            guard let grain = self.grain(at: max(0, seconds)) else { return }
            // A newer request came in while reading: it plays instead.
            guard self.latest.withLock({ $0 }) == number else { return }
            self.schedule(grain, deviceUID: deviceUID)
        }
    }

    /// Stops what is playing and lets the engine go, after a while of not
    /// being used.
    func stop() {
        latest.withLock { $0 += 1 }
        queue.async {
            self.node?.stop()
            self.engine?.stop()
            self.engine = nil
            self.node = nil
        }
    }

    /// The grain `play` would play at `seconds`, without playing it.
    func samples(at seconds: Double) async -> (left: [Float], right: [Float])? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.grain(at: max(0, seconds))) }
        }
    }

    // MARK: On the queue

    /// The grain's samples, left and right, reading the mix around it first
    /// if it isn't kept already. Nil when there is no sound there.
    private func grain(at seconds: Double) -> (left: [Float], right: [Float])? {
        let frames = Int(Self.grain * Self.sampleRate)
        if cache.map({ seconds < $0.start || seconds + Self.grain > $0.start + Double($0.left.count) / Self.sampleRate }) ?? true {
            cache = read(from: max(0, seconds - Self.before))
        }
        guard let cache else { return nil }
        let first = Int(((seconds - cache.start) * Self.sampleRate).rounded())
        guard first >= 0, first < cache.left.count else { return nil }
        let end = min(cache.left.count, first + frames)
        var left = Array(cache.left[first..<end]), right = Array(cache.right[first..<end])
        let fade = min(left.count / 2, Int(Self.fade * Self.sampleRate))
        for index in 0..<fade {
            let gain = Float(index) / Float(fade)
            left[index] *= gain
            right[index] *= gain
            left[left.count - 1 - index] *= gain
            right[right.count - 1 - index] *= gain
        }
        return (left, right)
    }

    /// Reads the mix from `start` for `before + after` seconds.
    private func read(from start: Double) -> (start: Double, left: [Float], right: [Float])? {
        guard let composed, let curves, !composed.audioTracks.isEmpty,
              let reader = try? AVAssetReader(asset: composed.composition)
        else { return nil }
        let output = AVAssetReaderAudioMixOutput(audioTracks: composed.composition.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
        ])
        output.audioMix = composed.audioMix(curves: curves)
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 48_000),
            duration: CMTime(seconds: Self.before + Self.after, preferredTimescale: 48_000)
        )
        guard reader.startReading() else { return nil }
        var left: [Float] = [], right: [Float] = []
        var first: Double?
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            if first == nil { first = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
            var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            for frame in 0..<samples.count / 2 {
                left.append(samples[2 * frame])
                right.append(samples[2 * frame + 1])
            }
        }
        guard let first, !left.isEmpty else { return nil }
        return (first, left, right)
    }

    private func schedule(_ grain: (left: [Float], right: [Float]), deviceUID: String?) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(grain.left.count)),
              let node = startEngine(deviceUID: deviceUID, format: format)
        else { return }
        buffer.frameLength = AVAudioFrameCount(grain.left.count)
        buffer.floatChannelData![0].update(from: grain.left, count: grain.left.count)
        buffer.floatChannelData![1].update(from: grain.right, count: grain.right.count)
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        node.play()
    }

    /// The engine, started on `deviceUID`'s device, made again when the
    /// device changed.
    private func startEngine(deviceUID: String?, format: AVAudioFormat) -> AVAudioPlayerNode? {
        if let engine, let node, engine.isRunning, self.deviceUID == deviceUID { return node }
        engine?.stop()
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        if let device = deviceUID.flatMap({ AudioDevices.device(uid: $0)?.id }), let unit = engine.outputNode.audioUnit {
            var device = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        guard (try? engine.start()) != nil else { return nil }
        self.engine = engine
        self.node = node
        self.deviceUID = deviceUID
        return node
    }
}
