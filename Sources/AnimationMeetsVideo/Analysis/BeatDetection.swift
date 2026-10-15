import Accelerate
import AVFoundation
import CoreMedia
import Foundation

/// The beats found in one asset's audio, in the asset's own time. This is
/// what beat detection saves; where the beats land on the timeline is worked
/// out from the clip's placement, so moving or trimming a clip needs no
/// re-detection.
struct BeatTrack: Equatable, Sendable {
    /// Units per second for `times`.
    var timescale: Int32
    /// Beat positions in `timescale` units, ascending.
    var times: [Int64]
    /// The typical tempo, the median over the beats; 0 when no beat was found.
    var beatsPerMinute: Double

    var isEmpty: Bool { times.isEmpty }

    /// The slowest and fastest tempo the beats keep up for a few beats,
    /// leaving out the slowest and fastest tenth so one odd gap doesn't
    /// count. Nil with too few beats to tell.
    var tempoRange: ClosedRange<Double>? {
        guard times.count >= 6 else { return nil }
        let gaps = zip(times.dropFirst(), times).map { Double($0 - $1) / Double(timescale) }
        let steady = (0...(gaps.count - 4)).map { index -> Double in
            gaps[index..<(index + 4)].sorted()[1...2].reduce(0, +) / 2
        }
        let tempos = steady.filter { $0 > 0 }.map { 60 / $0 }.sorted()
        guard !tempos.isEmpty else { return nil }
        let low = tempos[tempos.count / 10], high = tempos[tempos.count - 1 - tempos.count / 10]
        return low...high
    }

    /// Nothing was found. Saved like any other result so the audio is not
    /// analyzed again every time the project opens.
    static func none(timescale: Int32 = 1000) -> BeatTrack {
        BeatTrack(timescale: timescale, times: [], beatsPerMinute: 0)
    }

    /// Beats from `start` up to but not including `end`, in asset time.
    func beats(from start: CMTime, to end: CMTime) -> [CMTime] {
        let first = firstIndex(atOrAfter: start.convertScale(timescale, method: .roundTowardZero).value)
        let last = firstIndex(atOrAfter: end.convertScale(timescale, method: .roundTowardZero).value)
        guard first < last else { return [] }
        return times[first..<last].map { CMTime(value: $0, timescale: timescale) }
    }

    private func firstIndex(atOrAfter value: Int64) -> Int {
        times.lowerBound(of: value) { $0 }
    }

    // MARK: Serialization

    private static let magic: [UInt8] = Array("AMVB".utf8)
    /// 2 since the tempo may change; files of version 1 hold beats fitted to
    /// one steady tempo, so they are read as missing and detected again.
    private static let version: UInt32 = 2

    /// Compact binary form: a header, then every beat time. All integers are
    /// little endian; the tempo is a 32-bit float's bit pattern.
    func encoded() -> Data {
        var data = Data(Self.magic)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(Self.version)
        append(timescale)
        append(UInt32(times.count))
        append(Float(beatsPerMinute).bitPattern)
        for time in times { append(time) }
        return data
    }

    init(timescale: Int32, times: [Int64], beatsPerMinute: Double) {
        self.timescale = timescale
        self.times = times
        self.beatsPerMinute = beatsPerMinute
    }

    init(decoding data: Data) throws {
        var offset = 0
        func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw BeatTrackError.truncated }
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: (data.startIndex + offset)..<(data.startIndex + offset + size)) }
            offset += size
            return T(littleEndian: value)
        }

        guard data.count >= Self.magic.count, Array(data.prefix(Self.magic.count)) == Self.magic else {
            throw BeatTrackError.notABeatFile
        }
        offset = Self.magic.count
        let version = try read(UInt32.self)
        guard version == Self.version else { throw BeatTrackError.unsupportedVersion(version) }
        let timescale = try read(Int32.self)
        let count = Int(try read(UInt32.self))
        let tempo = Float(bitPattern: try read(UInt32.self))
        guard timescale > 0, data.count - offset == count * 8 else { throw BeatTrackError.truncated }

        var times: [Int64] = []
        times.reserveCapacity(count)
        for _ in 0..<count { times.append(try read(Int64.self)) }
        self.init(timescale: timescale, times: times, beatsPerMinute: Double(tempo))
    }
}

extension RandomAccessCollection {
    /// The index of the first element whose key is at or after `value`, or
    /// `endIndex` if none is, in a collection sorted by `key`.
    func lowerBound<Key: Comparable>(of value: Key, by key: (Element) -> Key) -> Index {
        var low = startIndex
        var count = self.count
        while count > 0 {
            let half = count / 2
            let middle = index(low, offsetBy: half)
            if key(self[middle]) < value {
                low = index(after: middle)
                count -= half + 1
            } else {
                count = half
            }
        }
        return low
    }
}

enum BeatTrackError: LocalizedError {
    case notABeatFile
    case unsupportedVersion(UInt32)
    case truncated

    var errorDescription: String? {
        switch self {
        case .notABeatFile: "This isn't a beat data file."
        case .unsupportedVersion(let version): "Beat data version \(version) isn't supported."
        case .truncated: "The beat data file is damaged."
        }
    }
}

// MARK: - Timeline markers

extension EditingProject {
    /// Where the beats of one timeline layer fall in timeline time: each clip
    /// on the layer contributes the beats inside its trimmed range, moved to
    /// where the clip sits. Empty for layers with no audio beats.
    ///
    /// Beats are found in the current file, but trims are in the original's
    /// time, so a replaced file's alignment offset is applied in between.
    func beatMarkers(in layer: TimelineLayer, tracks: [UUID: BeatTrack]) -> [CMTime] {
        var markers: [CMTime] = []
        for clip in layer.clips {
            guard case .media(let assetID) = clip.source, let track = tracks[assetID],
                  let asset = mediaClip(id: assetID), playsAudio(clip)
            else { continue }
            let fileStart = asset.fileTime(forSourceTime: clip.trimStart)
            for beat in track.beats(from: fileStart, to: asset.fileTime(forSourceTime: clip.trimEnd)) {
                // A retimed clip plays the file faster or slower, so a beat
                // lands where the footage under it does.
                let source = CMTimeAdd(clip.trimStart, CMTimeSubtract(beat, fileStart))
                markers.append(clip.timelineTime(forSourceTime: source))
            }
        }
        return markers.sorted { CMTimeCompare($0, $1) < 0 }
    }

    /// The layers of a timeline whose audio has beats, for the beat marker
    /// picker. A layer drops out as soon as it is deleted or its clips lose
    /// their beats, so nothing needs cleaning up.
    func beatLayers(in timeline: Timeline, tracks: [UUID: BeatTrack]) -> [TimelineLayer] {
        timeline.layers.filter { layerHasBeats($0, tracks: tracks) }
    }

    /// True when any clip on the layer plays audio with beats.
    func layerHasBeats(_ layer: TimelineLayer, tracks: [UUID: BeatTrack]) -> Bool {
        layer.clips.contains { clip in
            guard case .media(let id) = clip.source, let track = tracks[id], playsAudio(clip) else { return false }
            return !track.isEmpty
        }
    }
}

// MARK: - Detection

enum BeatDetector {
    /// Audio is analyzed as mono at this rate; beats need nothing above it.
    static let sampleRate = 22_050.0

    enum DetectionError: LocalizedError {
        case noAudioTrack
        case readerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "The file has no audio track to analyze."
            case .readerFailed(let reason): "Couldn't read the audio: \(reason)"
            }
        }
    }

    /// Finds the beats of the first audio track. `progress` receives 0...1 and
    /// may be called from a background thread. A track with no steady beat
    /// gives an empty result rather than an error. Cancelling the calling task
    /// stops reading and throws `CancellationError`.
    static func detect(url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> BeatTrack {
        let work = Task.detached(priority: .utility) {
            try await detectBeats(url: url, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func detectBeats(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> BeatTrack {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw DetectionError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds

        let handedOver = HandedOver(value: track)
        return try await SampleReading.run { isCancelled in
            let track = handedOver.value
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw DetectionError.readerFailed("unsupported audio format") }
            reader.add(output)
            guard reader.startReading() else {
                throw DetectionError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
            }

            let analyzer = OnsetAnalyzer()
            var originSamples: Int64?
            var lastReported = -1.0
            var chunk: [Float] = []

            while let sample = output.copyNextSampleBuffer() {
                if isCancelled() {
                    reader.cancelReading()
                    throw CancellationError()
                }
                let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
                if originSamples == nil, presentation.isNumeric {
                    originSamples = Int64((presentation.seconds * sampleRate).rounded())
                }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                let status = chunk.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { continue }
                chunk.withUnsafeBufferPointer { analyzer.append($0) }

                if duration > 0 {
                    let fraction = min((presentation.seconds) / duration, 1)
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress(fraction)
                    }
                }
            }

            if reader.status == .failed {
                throw DetectionError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
            }
            progress(1)

            let origin = originSamples ?? 0
            guard let beats = BeatTracker.track(envelope: analyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond) else {
                return .none(timescale: Int32(sampleRate))
            }
            return BeatTrack(
                timescale: Int32(sampleRate),
                times: beats.frames.map { origin + OnsetAnalyzer.centerSample(ofFrame: $0) },
                beatsPerMinute: beats.beatsPerMinute
            )
        }
    }
}

// MARK: - Onset strength

/// Turns audio into a curve of how much new sound starts at each moment
/// (spectral flux: the growth of each frequency's loudness from one short
/// frame to the next). It takes samples as they are decoded, so a long file
/// is never held in memory.
final class OnsetAnalyzer {
    static let windowSize = 1024
    static let hopSize = 256
    static var framesPerSecond: Double { BeatDetector.sampleRate / Double(hopSize) }

    /// The sample a frame is centered on, counted from the start of the audio.
    static func centerSample(ofFrame frame: Int) -> Int64 {
        Int64(frame * hopSize + windowSize / 2)
    }

    private(set) var envelope: [Float] = []

    private let log2n = vDSP_Length(10)
    private let fft: FFTSetup
    private let window: [Float]
    private var pending: [Float] = []
    private var previous: [Float]
    private var hasPrevious = false

    private var frame: [Float]
    private var realPart: [Float]
    private var imaginaryPart: [Float]
    private var magnitudes: [Float]
    private var scaled: [Float]
    private var compressed: [Float]

    init() {
        let bins = Self.windowSize / 2
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var hann = [Float](repeating: 0, count: Self.windowSize)
        vDSP_hann_window(&hann, vDSP_Length(Self.windowSize), Int32(vDSP_HANN_NORM))
        window = hann
        previous = [Float](repeating: 0, count: bins)
        frame = [Float](repeating: 0, count: Self.windowSize)
        realPart = [Float](repeating: 0, count: bins)
        imaginaryPart = [Float](repeating: 0, count: bins)
        magnitudes = [Float](repeating: 0, count: bins)
        scaled = [Float](repeating: 0, count: bins)
        compressed = [Float](repeating: 0, count: bins)
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        pending.append(contentsOf: samples)
        var start = 0
        while pending.count - start >= Self.windowSize {
            processFrame(startingAt: start)
            start += Self.hopSize
        }
        pending.removeFirst(start)
    }

    private func processFrame(startingAt start: Int) {
        let bins = Self.windowSize / 2
        pending.withUnsafeBufferPointer { samples in
            vDSP_vmul(samples.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(Self.windowSize))
        }

        realPart.withUnsafeMutableBufferPointer { real in
            imaginaryPart.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                frame.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(bins))
            }
        }

        // Log compression so a quiet hi-hat counts as much as a loud kick.
        var scale = 1000 / Float(Self.windowSize)
        vDSP_vsmul(magnitudes, 1, &scale, &scaled, 1, vDSP_Length(bins))
        var count = Int32(bins)
        vvlog1pf(&compressed, scaled, &count)

        var flux: Float = 0
        if hasPrevious {
            for bin in 0..<bins {
                flux += max(0, compressed[bin] - previous[bin])
            }
        }
        envelope.append(flux)
        hasPrevious = true
        swap(&previous, &compressed)
    }
}

// MARK: - Beat tracking

/// Finds the tempo of an onset curve and places beats on it, after Ellis,
/// "Beat Tracking by Dynamic Programming", extended to a tempo that changes:
/// the period is measured over short stretches, joined into one path that
/// may glide or jump, and the beats are the string that lands on strong
/// onsets while keeping close to the period at each moment.
enum BeatTracker {
    struct Result {
        /// Envelope frame of each beat.
        var frames: [Int]
        /// The typical tempo: the median over the beats.
        var beatsPerMinute: Double
    }

    static let minimumBPM = 60.0
    static let maximumBPM = 200.0
    /// Tempo guesses are pulled toward this, which settles the choice
    /// between a tempo and its double or half.
    static let preferredBPM = 120.0
    /// How strongly beats are held to the tempo versus chasing onsets.
    static let tightness = 100.0
    /// Shorter than this there isn't enough to tell a tempo from noise.
    static let minimumSeconds = 4.0
    /// The stretch each local tempo is measured over, and how far apart
    /// the stretches start. Long enough to hold several beats at the
    /// slowest tempo, short enough to follow a ramp.
    static let tempoWindowSeconds = 8.0
    static let tempoHopSeconds = 1.0
    /// What a change of tempo between neighbouring stretches costs, per
    /// squared octave, so a gradual ramp is cheap to follow.
    static let tempoGlide = 40.0
    /// The most a change between neighbouring stretches costs. A sudden
    /// change, or a flip to double or half tempo, is taken only once a few
    /// seconds of music are better explained by it.
    static let tempoJump = 2.5
    /// A change between neighbouring stretches bigger than this, in
    /// octaves (about 7%), is a jump rather than part of a ramp.
    static let suddenChange = 0.1

    static func track(envelope raw: [Float], framesPerSecond: Double) -> Result? {
        guard Double(raw.count) / framesPerSecond >= minimumSeconds,
              let onsets = prepared(raw, framesPerSecond: framesPerSecond),
              let periods = periods(of: onsets, framesPerSecond: framesPerSecond)
        else {
            return nil
        }
        let frames = chain(onsets, periods: periods)
        let kept = trimmed(frames, onsets: onsets)
        guard kept.count >= 2 else { return nil }
        let tempos = kept.map { 60 * framesPerSecond / periods.main[$0] }.sorted()
        return Result(frames: kept, beatsPerMinute: tempos[tempos.count / 2])
    }

    /// Keeps only what stands out from the surrounding second, then scales
    /// to unit spread so the settings above mean the same for any loudness.
    private static func prepared(_ raw: [Float], framesPerSecond: Double) -> [Float]? {
        let radius = max(1, Int(framesPerSecond / 2))
        var prefix = [Double](repeating: 0, count: raw.count + 1)
        for i in raw.indices { prefix[i + 1] = prefix[i] + Double(raw[i]) }
        var onsets = [Float](repeating: 0, count: raw.count)
        for i in raw.indices {
            let low = max(0, i - radius), high = min(raw.count, i + radius + 1)
            let mean = (prefix[high] - prefix[low]) / Double(high - low)
            onsets[i] = max(0, raw[i] - Float(mean))
        }
        var sumOfSquares: Float = 0
        vDSP_svesq(onsets, 1, &sumOfSquares, vDSP_Length(onsets.count))
        let spread = (sumOfSquares / Float(onsets.count)).squareRoot()
        guard spread > 1e-6 else { return nil }
        return onsets.map { $0 / spread }
    }

    /// The beat period in frames (fractional) at every frame. Where the
    /// tempo jumps, the frames between the two stretches' centers also get
    /// the period on the other side of the jump, and the beat chain takes
    /// whichever fits, so the onsets decide exactly where the change falls.
    struct Periods {
        var main: [Double]
        var alternative: [Double?]
    }

    /// The periods at every frame (see `Periods`). Each stretch
    /// of `tempoWindowSeconds` scores every candidate period by its
    /// autocorrelation, weighted toward everyday tempos; a Viterbi pass
    /// then picks one period per stretch, trading those scores against
    /// the cost of changing tempo, and the result is interpolated between
    /// the stretches' centers.
    private static func periods(of onsets: [Float], framesPerSecond: Double) -> Periods? {
        let shortest = max(2, Int((framesPerSecond * 60 / maximumBPM).rounded(.down)))
        let longest = Int((framesPerSecond * 60 / minimumBPM).rounded(.up))
        guard longest + 1 < onsets.count else { return nil }

        let length = min(onsets.count, max(Int(tempoWindowSeconds * framesPerSecond), 2 * (longest + 2)))
        let hop = max(1, Int(tempoHopSeconds * framesPerSecond))
        var starts = Array(stride(from: 0, to: onsets.count - length, by: hop))
        starts.append(onsets.count - length)

        let lags = Array(shortest...(longest + 1))
        let states = lags.count - 1
        let preferred = framesPerSecond * 60 / preferredBPM
        let weights = lags.map { lag -> Double in
            let octaves = log2(Double(lag) / preferred) / 1.4
            return exp(-0.5 * octaves * octaves)
        }

        // Onset peaks are a frame or two wide, so a period between two whole
        // frames splits its match across both lags and loses to a slower
        // tempo whose period happens to be whole. Blurring the curve a
        // little, for measuring tempo only, lets every period match fully.
        let blurred = blurred(onsets)

        // Each stretch's scores, scaled so its best is 1. A silent stretch
        // scores nothing, and the tempo carries through it.
        var scores: [[Double]] = []
        var anyEvidence = false
        blurred.withUnsafeBufferPointer { buffer in
            for start in starts {
                var row = lags.indices.map { index -> Double in
                    let lag = lags[index]
                    let overlap = length - lag
                    guard overlap > 0 else { return 0 }
                    var sum: Float = 0
                    vDSP_dotpr(buffer.baseAddress! + start, 1, buffer.baseAddress! + start + lag, 1, &sum, vDSP_Length(overlap))
                    return Double(sum) / Double(overlap) * weights[index]
                }
                let best = row[..<states].max() ?? 0
                if best > 0 {
                    anyEvidence = true
                    row = row.map { max(0, $0) / best }
                } else {
                    row = row.map { _ in 0 }
                }
                scores.append(row)
            }
        }
        guard anyEvidence else { return nil }

        // Viterbi over the candidate periods.
        let logLags = lags.map { log2(Double($0)) }
        var total = Array(scores[0][..<states])
        var backlinks: [[Int]] = []
        for row in scores.dropFirst() {
            var next = [Double](repeating: -.infinity, count: states)
            var links = [Int](repeating: 0, count: states)
            for state in 0..<states {
                var best = -Double.infinity
                for previous in 0..<states {
                    let change = logLags[state] - logLags[previous]
                    let candidate = total[previous] - min(tempoGlide * change * change, tempoJump)
                    if candidate > best {
                        best = candidate
                        links[state] = previous
                    }
                }
                next[state] = best + row[state]
            }
            total = next
            backlinks.append(links)
        }
        var path = [Int](repeating: 0, count: scores.count)
        path[path.count - 1] = total.indices.max { total[$0] < total[$1] } ?? 0
        for index in stride(from: path.count - 1, to: 0, by: -1) {
            path[index - 1] = backlinks[index - 1][path[index]]
        }

        // Refine each stretch's period between frames: at 86 frames a
        // second, one frame is several BPM.
        let periods = path.indices.map { index -> Double in
            let state = path[index], row = scores[index]
            guard state > 0 else { return Double(lags[state]) }
            let left = row[state - 1], middle = row[state], right = row[state + 1]
            let curve = left - 2 * middle + right
            guard curve < 0 else { return Double(lags[state]) }
            return Double(lags[state]) + min(max(0.5 * (left - right) / curve, -0.5), 0.5)
        }

        let centers = starts.map { Double($0) + Double(length) / 2 }
        var perFrame = [Double](repeating: periods[0], count: onsets.count)
        var alternative = [Double?](repeating: nil, count: onsets.count)
        var segment = 0
        for frame in onsets.indices {
            let position = Double(frame)
            while segment + 1 < centers.count, centers[segment + 1] <= position { segment += 1 }
            if position <= centers[0] {
                perFrame[frame] = periods[0]
            } else if segment + 1 >= centers.count {
                perFrame[frame] = periods[periods.count - 1]
            } else {
                let fraction = (position - centers[segment]) / (centers[segment + 1] - centers[segment])
                let before = periods[segment], after = periods[segment + 1]
                if abs(log2(after / before)) > suddenChange {
                    // A jump, not a glide: easing into it would put beats between the two tempos.
                    perFrame[frame] = fraction < 0.5 ? before : after
                } else {
                    perFrame[frame] = before + fraction * (after - before)
                }
            }
        }
        // The change can fall anywhere the two stretches overlap, so the
        // chain may use either period from a stretch before the jump's
        // midpoint to a stretch after it.
        for segment in 0..<max(0, centers.count - 1) {
            let before = periods[segment], after = periods[segment + 1]
            guard abs(log2(after / before)) > suddenChange else { continue }
            let middle = (centers[segment] + centers[segment + 1]) / 2
            let reach = Double(hop) * 1.5
            let low = max(0, Int(middle - reach)), high = min(onsets.count - 1, Int(middle + reach))
            guard low <= high else { continue }
            for frame in low...high {
                alternative[frame] = Double(frame) < middle ? after : before
            }
        }
        return Periods(main: perFrame, alternative: alternative)
    }

    /// The curve smoothed with a small Gaussian (a deviation of 1.5 frames).
    private static func blurred(_ onsets: [Float]) -> [Float] {
        let kernel: [Float] = (-4...4).map { exp(-Float($0 * $0) / (2 * 1.5 * 1.5)) }
        var result = [Float](repeating: 0, count: onsets.count)
        for index in onsets.indices {
            var total: Float = 0
            for (offset, weight) in kernel.enumerated() {
                let position = index + offset - 4
                guard onsets.indices.contains(position) else { continue }
                total += onsets[position] * weight
            }
            result[index] = total
        }
        return result
    }

    /// Dynamic programming: each frame's best score is its onset strength
    /// plus the best earlier beat, minus a penalty for straying from the
    /// period at that frame.
    private static func chain(_ onsets: [Float], periods: Periods) -> [Int] {
        let count = onsets.count
        let longestPeriod = max(periods.main.max() ?? 2, periods.alternative.compactMap { $0 }.max() ?? 2)
        let farthestAnywhere = max(2, Int((longestPeriod * 2).rounded()))
        let logGaps = (0...farthestAnywhere).map { log(Double(max($0, 1))) }

        var score = [Double](repeating: 0, count: count)
        var backlink = [Int](repeating: -1, count: count)
        for t in 0..<count {
            let period = periods.main[t]
            let other = periods.alternative[t] ?? period
            let logPeriod = log(period), logOther = log(other)
            let nearest = max(1, Int((min(period, other) / 2).rounded()))
            let farthest = max(nearest + 1, Int((max(period, other) * 2).rounded()))
            var best = 0.0
            var from = -1
            if t - nearest >= 0 {
                for gap in nearest...min(farthest, t) {
                    let stray = min(abs(logGaps[gap] - logPeriod), abs(logGaps[gap] - logOther))
                    let candidate = score[t - gap] - tightness * stray * stray
                    if candidate > best {
                        best = candidate
                        from = t - gap
                    }
                }
            }
            score[t] = Double(onsets[t]) + best
            backlink[t] = from
        }

        let peaks = (1..<(count - 1)).filter { score[$0] >= score[$0 - 1] && score[$0] > score[$0 + 1] }
        guard !peaks.isEmpty else { return [] }
        let sorted = peaks.map { score[$0] }.sorted()
        let threshold = 0.5 * sorted[sorted.count / 2]
        guard let last = peaks.last(where: { score[$0] >= threshold }) else { return [] }

        var frames: [Int] = []
        var cursor = last
        while cursor >= 0 {
            frames.append(cursor)
            cursor = backlink[cursor]
        }
        return frames.reversed()
    }

    /// Drops beats at the start and end that sit on near silence; the chain
    /// keeps stepping at the tempo through quiet stretches.
    private static func trimmed(_ frames: [Int], onsets: [Float]) -> [Int] {
        guard frames.count > 2 else { return frames }
        let strengths = frames.map { Double(onsets[$0]) }
        let weights = [1.0, 2, 3, 2, 1]
        let smoothed = strengths.indices.map { index -> Double in
            var total = 0.0, weightSum = 0.0
            for (offset, weight) in weights.enumerated() {
                let position = index + offset - 2
                guard strengths.indices.contains(position) else { continue }
                total += strengths[position] * weight
                weightSum += weight
            }
            return total / weightSum
        }
        let rms = (smoothed.map { $0 * $0 }.reduce(0, +) / Double(smoothed.count)).squareRoot()
        let threshold = 0.5 * rms
        guard let first = smoothed.firstIndex(where: { $0 >= threshold }),
              let last = smoothed.lastIndex(where: { $0 >= threshold })
        else {
            return []
        }
        return Array(frames[first...last])
    }
}
