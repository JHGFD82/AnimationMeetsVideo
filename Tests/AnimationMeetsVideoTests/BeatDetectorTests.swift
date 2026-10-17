import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A click every `interval` seconds, starting at `first`: a short decaying
/// noise burst, which is what a drum hit looks like to an onset detector.
private func clickTrack(seconds: Double, interval: Double, first: Double, sampleRate: Double) -> [Float] {
    var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
    var generator = SystemRandomNumberGenerator()
    var time = first
    while time < seconds {
        let start = Int(time * sampleRate)
        let length = Int(0.03 * sampleRate)
        for i in 0..<length where start + i < samples.count {
            let envelope = Float(exp(-Double(i) / (0.006 * sampleRate)))
            samples[start + i] = Float.random(in: -1...1, using: &generator) * envelope * 0.8
        }
        time += interval
    }
    return samples
}

/// Clicks at the given times, like `clickTrack`.
private func clicks(at times: [Double], seconds: Double, sampleRate: Double) -> [Float] {
    var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
    var generator = SystemRandomNumberGenerator()
    for time in times {
        let start = Int(time * sampleRate)
        let length = Int(0.03 * sampleRate)
        for i in 0..<length where start + i < samples.count {
            let envelope = Float(exp(-Double(i) / (0.006 * sampleRate)))
            samples[start + i] = Float.random(in: -1...1, using: &generator) * envelope * 0.8
        }
    }
    return samples
}

/// Click times for a tempo that follows `bpm(t)`, from `first` to `seconds`.
private func clickTimes(seconds: Double, first: Double, bpm: (Double) -> Double) -> [Double] {
    var times: [Double] = []
    var time = first
    while time < seconds {
        times.append(time)
        time += 60 / bpm(time)
    }
    return times
}

/// How well detected beats match the clicks, away from the first and last
/// two seconds: the share of clicks with a beat within 50 ms, and the share
/// of beats within 50 ms of a click.
private func agreement(beats: [Double], clicks: [Double], seconds: Double) -> (found: Double, accurate: Double) {
    func near(_ time: Double, _ others: [Double]) -> Bool { others.contains { abs($0 - time) < 0.05 } }
    let inner = { (time: Double) in time > 2 && time < seconds - 2 }
    let innerClicks = clicks.filter(inner), innerBeats = beats.filter(inner)
    let found = Double(innerClicks.filter { near($0, beats) }.count) / Double(max(innerClicks.count, 1))
    let accurate = Double(innerBeats.filter { near($0, clicks) }.count) / Double(max(innerBeats.count, 1))
    return (found, accurate)
}

private func trackBeats(_ samples: [Float]) throws -> (seconds: [Double], result: BeatTracker.Result) {
    let analyzer = OnsetAnalyzer()
    samples.withUnsafeBufferPointer { analyzer.append($0) }
    let result = try #require(try BeatTracker.track(envelope: analyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond))
    let seconds = result.frames.map { Double(OnsetAnalyzer.centerSample(ofFrame: $0)) / BeatDetector.sampleRate }
    return (seconds, result)
}

private func seconds(_ time: CMTime) -> Double { time.seconds }

@Suite struct BeatDetectorTests {
    // MARK: Tracking

    @Test func findsTheTempoAndPlacementOfAClickTrack() throws {
        let rate = BeatDetector.sampleRate
        let samples = clickTrack(seconds: 12, interval: 0.5, first: 0.1, sampleRate: rate)
        let analyzer = OnsetAnalyzer()
        samples.withUnsafeBufferPointer { analyzer.append($0) }

        let result = try #require(try BeatTracker.track(envelope: analyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond))

        #expect(abs(result.beatsPerMinute - 120) < 3)
        #expect(result.frames.count >= 18)
        for frame in result.frames {
            let beat = Double(OnsetAnalyzer.centerSample(ofFrame: frame)) / rate
            let nearest = ((beat - 0.1) / 0.5).rounded() * 0.5 + 0.1
            #expect(abs(beat - nearest) < 0.05, "beat at \(beat)s is off the clicks")
        }
    }

    @Test func slowerClicksGiveTheirOwnTempo() throws {
        let rate = BeatDetector.sampleRate
        let samples = clickTrack(seconds: 16, interval: 60.0 / 90.0, first: 0.3, sampleRate: rate)
        let analyzer = OnsetAnalyzer()
        samples.withUnsafeBufferPointer { analyzer.append($0) }

        let result = try #require(try BeatTracker.track(envelope: analyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond))

        #expect(abs(result.beatsPerMinute - 90) < 3)
    }

    @Test func followsATempoThatRampsUp() throws {
        let length = 40.0
        let times = clickTimes(seconds: length, first: 0.2) { 90 + 50 * $0 / length }
        let (beats, result) = try trackBeats(clicks(at: times, seconds: length, sampleRate: BeatDetector.sampleRate))

        let match = agreement(beats: beats, clicks: times, seconds: length)
        #expect(match.found > 0.9, "only \(match.found) of the clicks have a beat")
        #expect(match.accurate > 0.9, "only \(match.accurate) of the beats are on a click")
        #expect(abs(result.beatsPerMinute - 115) < 10)
    }

    @Test func followsASuddenChangeOfTempo() throws {
        let length = 30.0
        let times = clickTimes(seconds: length, first: 0.2) { $0 < 15 ? 100 : 150 }
        let (beats, _) = try trackBeats(clicks(at: times, seconds: length, sampleRate: BeatDetector.sampleRate))

        let match = agreement(beats: beats, clicks: times, seconds: length)
        #expect(match.found > 0.95, "only \(match.found) of the clicks have a beat")
        #expect(match.accurate > 0.95, "only \(match.accurate) of the beats are on a click")
        // Not even the beats around the change stray between the two tempos.
        let around = beats.filter { $0 > 12 && $0 < 18 }
        #expect(around.allSatisfy { beat in times.contains { abs($0 - beat) < 0.05 } })
    }

    /// The tempo of the median gap between `seconds`.
    private func medianTempo(_ seconds: [Double]) -> Double {
        let gaps = zip(seconds.dropFirst(), seconds).map { $0 - $1 }.sorted()
        let middle = gaps.count / 2
        let median = gaps.count.isMultiple(of: 2) ? (gaps[middle - 1] + gaps[middle]) / 2 : gaps[middle]
        return 60 / median
    }

    @Test func theTempoIsTheOneTheBeatsKeepAcrossAnAbruptChange() throws {
        // A third at 100 BPM, then 150: most beats are at 150.
        let length = 30.0
        let times = clickTimes(seconds: length, first: 0.2) { $0 < 10 ? 100 : 150 }
        let (beats, result) = try trackBeats(clicks(at: times, seconds: length, sampleRate: BeatDetector.sampleRate))

        #expect(abs(result.beatsPerMinute - 150) < 3)
        #expect(abs(result.beatsPerMinute - medianTempo(beats)) < 1e-6)
        let track = try BeatTrack(timescale: Int32(BeatDetector.sampleRate),
                                  times: result.frames.map { OnsetAnalyzer.centerSample(ofFrame: $0) },
                                  beatsPerMinute: result.beatsPerMinute)
        let range = try #require(track.tempoRange)
        #expect(range.contains(result.beatsPerMinute))
    }

    @Test func theTempoMatchesTheBeatsWhereTheChainTookTheOtherPeriod() throws {
        // Around the change the chain may step with the period from either
        // side; the tempo reported still comes from the steps it took.
        let length = 30.0
        let times = clickTimes(seconds: length, first: 0.2) { $0 < 15 ? 100 : 150 }
        let (beats, result) = try trackBeats(clicks(at: times, seconds: length, sampleRate: BeatDetector.sampleRate))

        #expect(abs(result.beatsPerMinute - medianTempo(beats)) < 1e-6)
        let around = zip(beats.dropFirst(), beats).filter { $1 > 12 && $0 < 18 }.map { 60 / ($0 - $1) }
        #expect(around.contains { abs($0 - 100) < 5 })
        #expect(around.contains { abs($0 - 150) < 5 })
    }

    @Test func theTempoOfFramesIsTheirMedianGap() {
        let rate = 100.0
        #expect(BeatTracker.beatsPerMinute(ofFrames: [0, 50, 100, 200], framesPerSecond: rate) == 120)
        #expect(BeatTracker.beatsPerMinute(ofFrames: [0, 50, 150, 200, 300], framesPerSecond: rate) == 80)
        #expect(BeatTracker.beatsPerMinute(ofFrames: [10], framesPerSecond: rate) == nil)
    }

    @Test func aSteadyTempoStaysSteady() throws {
        let length = 40.0
        let times = clickTimes(seconds: length, first: 0.3) { _ in 120 }
        let (beats, result) = try trackBeats(clicks(at: times, seconds: length, sampleRate: BeatDetector.sampleRate))

        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - 0.5) < 0.03 }, "a gap strays from 0.5 s: \(gaps)")
        #expect(abs(result.beatsPerMinute - 120) < 2)
    }

    @Test func followsASlowdown() throws {
        let length = 40.0
        let times = clickTimes(seconds: length, first: 0.2) { 150 - 60 * $0 / length }
        let (beats, _) = try trackBeats(clicks(at: times, seconds: length, sampleRate: BeatDetector.sampleRate))

        let match = agreement(beats: beats, clicks: times, seconds: length)
        #expect(match.found > 0.9, "only \(match.found) of the clicks have a beat")
        #expect(match.accurate > 0.9, "only \(match.accurate) of the beats are on a click")
    }

    @Test func silenceAndShortAudioHaveNoBeats() throws {
        let analyzer = OnsetAnalyzer()
        [Float](repeating: 0, count: 22_050 * 10).withUnsafeBufferPointer { analyzer.append($0) }
        let silent = try BeatTracker.track(envelope: analyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond)
        #expect(silent == nil)

        let short = clickTrack(seconds: 2, interval: 0.5, first: 0.1, sampleRate: BeatDetector.sampleRate)
        let shortAnalyzer = OnsetAnalyzer()
        short.withUnsafeBufferPointer { shortAnalyzer.append($0) }
        let brief = try BeatTracker.track(envelope: shortAnalyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond)
        #expect(brief == nil)
    }

    /// A pulse every half second at the analyzer's frame rate.
    private func pulses(seconds: Double) -> [Float] {
        let rate = OnsetAnalyzer.framesPerSecond
        return (0..<Int(seconds * rate)).map { Int(Double($0).truncatingRemainder(dividingBy: rate / 2)) == 0 ? 5 : 0 }
    }

    @Test func invalidFrameRatesAreRejected() {
        let envelope = pulses(seconds: 10)
        for rate in [0, -86, .infinity, -.infinity, .nan] as [Double] {
            #expect(throws: BeatTracker.InputError.self, "\(rate)") {
                _ = try BeatTracker.track(envelope: envelope, framesPerSecond: rate)
            }
        }
    }

    @Test func onsetsThatArentFiniteAndNonnegativeAreRejected() {
        for bad in [Float.nan, .infinity, -.infinity, -1] {
            var envelope = pulses(seconds: 10)
            envelope[100] = bad
            #expect(throws: BeatTracker.InputError.invalidOnset(frame: 100), "\(bad)") {
                _ = try BeatTracker.track(envelope: envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond)
            }
        }
    }

    @Test func veryShortOrOddlyScaledCurvesHaveNoBeatsAndDontTrap() throws {
        let rate = OnsetAnalyzer.framesPerSecond
        #expect(try BeatTracker.track(envelope: [], framesPerSecond: rate) == nil)
        #expect(try BeatTracker.track(envelope: [1], framesPerSecond: rate) == nil)
        #expect(try BeatTracker.track(envelope: pulses(seconds: 3.9), framesPerSecond: rate) == nil)
        // Rates that are valid but make the tempo range smaller than a frame, or the curve far too short.
        #expect(try BeatTracker.track(envelope: pulses(seconds: 10), framesPerSecond: 0.5) == nil)
        #expect(try BeatTracker.track(envelope: pulses(seconds: 10), framesPerSecond: .leastNonzeroMagnitude) == nil)
        #expect(try BeatTracker.track(envelope: pulses(seconds: 10), framesPerSecond: 1e300) == nil)
        // Values near Float's limit must not overflow into infinities.
        let huge = pulses(seconds: 10).map { $0 / 5 * Float.greatestFiniteMagnitude }
        _ = try BeatTracker.track(envelope: huge, framesPerSecond: rate)
    }

    // MARK: Spectrum

    @Test func aConstantFrameHasNoInteriorEnergy() {
        let magnitudes = OnsetAnalyzer().magnitudes(ofFrame: [Float](repeating: 1, count: OnsetAnalyzer.windowSize))
        #expect(magnitudes.count == OnsetAnalyzer.windowSize / 2)
        // All of it is DC, which is left out rather than reported in bin 0.
        #expect(magnitudes.allSatisfy { abs($0) < 1e-3 }, "largest: \(magnitudes.max() ?? 0)")
    }

    @Test func aNyquistFrameIsNotReportedAsAnyBin() {
        let alternating = (0..<OnsetAnalyzer.windowSize).map { $0.isMultiple(of: 2) ? Float(1) : -1 }
        let magnitudes = OnsetAnalyzer().magnitudes(ofFrame: alternating)
        #expect(magnitudes.allSatisfy { abs($0) < 1e-3 }, "largest: \(magnitudes.max() ?? 0)")
    }

    @Test func anInteriorToneLandsInItsOwnBin() throws {
        let size = OnsetAnalyzer.windowSize
        let tone = (0..<size).map { Float(cos(2 * Double.pi * 37 * Double($0) / Double(size))) }
        let magnitudes = OnsetAnalyzer().magnitudes(ofFrame: tone)
        let peak = try #require(magnitudes.indices.max { magnitudes[$0] < magnitudes[$1] })
        #expect(peak == 37)
        #expect(magnitudes[0] == 0)
    }

    // MARK: End to end

    @Test func detectsBeatsInAnAudioFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-beats-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 44_100.0
        let samples = clickTrack(seconds: 12, interval: 0.5, first: 0.1, sampleRate: rate)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }

        let track = try await BeatDetector.detect(url: url)

        #expect(!track.isEmpty)
        #expect(abs(track.beatsPerMinute - 120) < 3)
        for beat in track.beats(from: .zero, to: CMTime(seconds: 13, preferredTimescale: 600)) {
            let nearest = ((beat.seconds - 0.1) / 0.5).rounded() * 0.5 + 0.1
            #expect(abs(beat.seconds - nearest) < 0.05)
        }
    }

    @Test func aFileWithoutAudioIsAnError() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-noaudio-\(UUID().uuidString).txt")
        try Data("nope".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) {
            _ = try await BeatDetector.detect(url: url)
        }
    }

    // MARK: BeatTrack

    private let sample = try! BeatTrack(timescale: 1000, times: [0, 500, 1000, 1500, 2000], beatsPerMinute: 120)

    @Test func beatsInARangeIncludeTheStartAndExcludeTheEnd() {
        let beats = sample.beats(from: CMTime(value: 500, timescale: 1000), to: CMTime(value: 1500, timescale: 1000))
        #expect(beats.map(seconds) == [0.5, 1.0])
        #expect(sample.beats(from: CMTime(seconds: 3, preferredTimescale: 600), to: CMTime(seconds: 4, preferredTimescale: 600)).isEmpty)
    }

    @Test func rangeBoundsBetweenTwoTicksAreNotRoundedOntoEither() {
        // 500.5 ms leaves out the beat at 500 ms; 1500.5 ms keeps the one at 1500 ms.
        let beats = sample.beats(from: CMTime(value: 1001, timescale: 2000), to: CMTime(value: 3001, timescale: 2000))
        #expect(beats.map(seconds) == [1.0, 1.5])
        // 499.5 ms keeps 500 ms; 1499.5 ms leaves out 1500 ms.
        let earlier = sample.beats(from: CMTime(value: 999, timescale: 2000), to: CMTime(value: 2999, timescale: 2000))
        #expect(earlier.map(seconds) == [0.5, 1.0])
    }

    @Test func beatsAtEitherEndOfTheRange() {
        let exact = sample.beats(from: CMTime(value: 1, timescale: 2), to: CMTime(value: 3, timescale: 2))
        #expect(exact.map(seconds) == [0.5, 1.0])
        let all = sample.beats(from: .zero, to: CMTime(value: 2001, timescale: 1000))
        #expect(all.count == 5)
        #expect(sample.beats(from: .zero, to: .zero).isEmpty)
    }

    @Test func negativeTimesAreFoundToo() throws {
        let track = try BeatTrack(timescale: 1000, times: [-1000, -500, 0, 500], beatsPerMinute: 120)
        // -500.5 ms up to -0.5 ms: the beats at -500 ms only.
        let beats = track.beats(from: CMTime(value: -1001, timescale: 2000), to: CMTime(value: -1, timescale: 2000))
        #expect(beats.map(seconds) == [-0.5])
        // -999.5 ms up to 0.5 ms: -500 and 0.
        let more = track.beats(from: CMTime(value: -1999, timescale: 2000), to: CMTime(value: 1, timescale: 2000))
        #expect(more.map(seconds) == [-0.5, 0])
    }

    @Test func unusableRangesHaveNoBeats() {
        let end = CMTime(value: 3, timescale: 2)
        #expect(sample.beats(from: end, to: .zero).isEmpty, "reversed")
        #expect(sample.beats(from: .invalid, to: end).isEmpty)
        #expect(sample.beats(from: .zero, to: .positiveInfinity).isEmpty)
        #expect(sample.beats(from: .negativeInfinity, to: end).isEmpty)
        #expect(sample.beats(from: .zero, to: .indefinite).isEmpty)
        #expect(sample.beats(from: CMTime(value: 0, timescale: 0), to: end).isEmpty)
    }

    @Test func encodingRoundTrips() throws {
        let decoded = try BeatTrack(decoding: sample.encoded())
        #expect(decoded.times == sample.times)
        #expect(decoded.timescale == 1000)
        #expect(abs(decoded.beatsPerMinute - 120) < 0.001)

        let empty = try BeatTrack(decoding: BeatTrack.none().encoded())
        #expect(empty.isEmpty)
    }

    @Test func lowerBoundFindsTheFirstElementAtOrAfterTheValue() {
        let values = [1, 3, 3, 5]
        #expect(values.lowerBound(of: 0) { $0 } == 0)
        #expect(values.lowerBound(of: 3) { $0 } == 1)
        #expect(values.lowerBound(of: 4) { $0 } == 3)
        #expect(values.lowerBound(of: 6) { $0 } == 4)
        #expect([Int]().lowerBound(of: 1) { $0 } == 0)
        #expect(values[1...].lowerBound(of: 5) { $0 } == 3)
    }

    @Test func beatsFromTheSteadyOnlyVersionAreReadAsMissing() {
        var old = sample.encoded()
        old.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(1).littleEndian) { Data($0) })
        #expect(throws: BeatTrackError.self) { try BeatTrack(decoding: old) }
    }

    @Test func theTempoRangeSpansARampButNotASteadyBeat() throws {
        let steady = try BeatTrack(timescale: 1000, times: Array(stride(from: 0, to: 20_000, by: 500)), beatsPerMinute: 120)
        #expect(steady.tempoRange == 120...120)

        let times = clickTimes(seconds: 40, first: 0, bpm: { 90 + 50 * $0 / 40 })
        let ramp = try BeatTrack(timescale: 1000, times: times.map { Int64($0 * 1000) }, beatsPerMinute: 115)
        let range = try #require(ramp.tempoRange)
        #expect(abs(range.lowerBound - 95) < 5)
        #expect(abs(range.upperBound - 135) < 5)
    }

    @Test func damagedDataIsRejected() {
        #expect(throws: BeatTrackError.self) { try BeatTrack(decoding: Data("nonsense".utf8)) }
        #expect(throws: BeatTrackError.self) { try BeatTrack(decoding: sample.encoded().dropLast(3)) }
        #expect(throws: BeatTrackError.self) { try BeatTrack(decoding: Data()) }
    }

    /// A version 2 beat file with the given header and times, valid or not.
    private func beatFile(timescale: Int32 = 1000, count: UInt32? = nil, tempo: Float = 120, times: [Int64]) -> Data {
        var data = Data("AMVB".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(2))
        append(timescale)
        append(count ?? UInt32(times.count))
        append(tempo.bitPattern)
        for time in times { append(time) }
        return data
    }

    private func isInvalid(_ data: Data) -> Bool {
        do {
            _ = try BeatTrack(decoding: data)
            return false
        } catch BeatTrackError.invalidData {
            return true
        } catch {
            return false
        }
    }

    @Test func corruptValuesAreRejectedAsInvalid() {
        #expect(isInvalid(beatFile(times: [0, 1000, 500])), "unsorted")
        #expect(isInvalid(beatFile(times: [0, 500, 500])), "duplicate")
        #expect(isInvalid(beatFile(timescale: 0, times: [0, 500])))
        #expect(isInvalid(beatFile(timescale: -1000, times: [0, 500])))
        #expect(isInvalid(beatFile(tempo: .nan, times: [0, 500])))
        #expect(isInvalid(beatFile(tempo: .infinity, times: [0, 500])))
        #expect(isInvalid(beatFile(tempo: -120, times: [0, 500])))
        #expect(isInvalid(beatFile(tempo: 0, times: [0, 500])), "beats without a tempo")
        #expect(isInvalid(beatFile(tempo: 120, times: [])), "a tempo without beats")
    }

    @Test func aCountThatDisagreesWithTheDataIsTruncation() {
        #expect(throws: BeatTrackError.truncated) { try BeatTrack(decoding: self.beatFile(count: 3, times: [0, 500])) }
        #expect(throws: BeatTrackError.truncated) { try BeatTrack(decoding: self.beatFile(count: .max, times: [0, 500])) }
        #expect(throws: BeatTrackError.truncated) { try BeatTrack(decoding: self.beatFile(count: 1, times: [0, 500])) }
    }

    @Test func constructionEnforcesTheSameInvariants() {
        #expect(throws: BeatTrackError.self) { try BeatTrack(timescale: 1000, times: [5, 5], beatsPerMinute: 120) }
        #expect(throws: BeatTrackError.self) { try BeatTrack(timescale: 1000, times: [0, 500], beatsPerMinute: -.infinity) }
        #expect(throws: BeatTrackError.self) { try BeatTrack(timescale: 1000, times: [0, 500], beatsPerMinute: 1e300) }
        #expect(throws: BeatTrackError.self) { try BeatTrack(timescale: 0, times: [], beatsPerMinute: 0) }
        #expect(BeatTrack.none(timescale: 0).timescale > 0)
    }

    @Test func extremeTimesRoundTripWithoutOverflow() throws {
        let times: [Int64] = [.min, .min + 1, -1, 0, 1, .max - 1, .max]
        let track = try BeatTrack(timescale: 1, times: times, beatsPerMinute: 60)

        let decoded = try BeatTrack(decoding: track.encoded())

        #expect(decoded == track)
        // The gaps between these overflow an Int64; the range just has to come out without trapping.
        let range = try #require(decoded.tempoRange)
        #expect(range.lowerBound > 0)
    }

    // MARK: Timeline markers

    private func audioAsset(_ name: String = "song.wav") -> MediaClip {
        MediaClip(
            name: name, kind: .audio, url: URL(fileURLWithPath: "/tmp/\(name)"),
            duration: CMTime(seconds: 10, preferredTimescale: 600), frameRate: 0,
            colorSpace: .rec709, codecName: "Test", hasAudio: true
        )
    }

    private func add(_ asset: MediaClip, to project: inout EditingProject) -> (layerID: UUID, clipID: UUID) {
        project.importClip(asset, intoTimeline: project.rootTimelineID)!
    }

    private func t(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    @Test func markersFollowTheClipsTrimAndPlacement() throws {
        var project = EditingProject.empty
        let asset = audioAsset()
        let ids = add(asset, to: &project)
        let timeline = project.timelines[0]
        var layer = try #require(timeline.layer(id: ids.layerID))
        // Plays the asset from 0.75s to 2.25s, starting at 10s on the timeline.
        layer.clips[0].trimStart = t(0.75)
        layer.clips[0].trimEnd = t(2.25)
        layer.clips[0].startOffset = t(10)

        let markers = project.beatMarkers(in: layer, tracks: [asset.id: sample])

        #expect(markers.map { seconds($0) } == [10.25, 10.75, 11.25])
    }

    @Test func markersOfAReplacedFileAreShiftedByItsOffset() throws {
        var project = EditingProject.empty
        let asset = audioAsset()
        let ids = add(asset, to: &project)
        // Original time t is at t + 0.5s in the current file, where the beats were found.
        project.setAlignmentOffset(t(0.5), forAsset: asset.id)
        var layer = try #require(project.timelines[0].layer(id: ids.layerID))
        layer.clips[0].trimStart = t(0.75)
        layer.clips[0].trimEnd = t(2.25)
        layer.clips[0].startOffset = t(10)

        let markers = project.beatMarkers(in: layer, tracks: [asset.id: sample])

        // File beats 1.5 and 2.0 fall in the file range 1.25..<2.75.
        #expect(markers.map { seconds($0) } == [10.25, 10.75])
    }

    @Test func markersCombineEveryClipOnTheLayerInOrder() throws {
        var project = EditingProject.empty
        let asset = audioAsset()
        let ids = add(asset, to: &project)
        var layer = try #require(project.timelines[0].layer(id: ids.layerID))
        layer.clips[0].trimStart = .zero
        layer.clips[0].trimEnd = t(1)
        layer.clips[0].startOffset = t(5)
        var second = layer.clips[0]
        second.id = UUID()
        second.startOffset = t(0)
        layer.clips.append(second)

        let markers = project.beatMarkers(in: layer, tracks: [asset.id: sample])

        #expect(markers.map { seconds($0) } == [0, 0.5, 5, 5.5])
    }

    @Test func layersWithoutBeatsAreNotOffered() throws {
        var project = EditingProject.empty
        let song = audioAsset("song.wav"), quiet = audioAsset("quiet.wav"), unanalyzed = audioAsset("new.wav")
        let first = add(song, to: &project)
        let second = add(quiet, to: &project)
        _ = add(unanalyzed, to: &project)
        let tracks = [song.id: sample, quiet.id: BeatTrack.none()]

        let offered = project.beatLayers(in: project.timelines[0], tracks: tracks)

        #expect(offered.map(\.id) == [first.layerID])
        #expect(!offered.contains { $0.id == second.layerID })
    }

    @Test func aLayerWhoseTrimsMissEveryBeatIsNotOffered() throws {
        var project = EditingProject.empty
        let song = audioAsset()
        let ids = add(song, to: &project)
        let index = try #require(project.timelines[0].layers.firstIndex { $0.id == ids.layerID })
        // Between the beats at 0.5 s and 1.0 s, and ending exactly on the second.
        project.timelines[0].layers[index].clips[0].trimStart = t(0.6)
        project.timelines[0].layers[index].clips[0].trimEnd = t(1)
        let tracks = [song.id: sample]

        #expect(project.beatLayers(in: project.timelines[0], tracks: tracks).isEmpty)

        project.timelines[0].layers[index].clips[0].trimEnd = t(1.1)
        let layer = project.timelines[0].layers[index]
        #expect(project.layerHasBeats(layer, tracks: tracks))
        #expect(project.beatMarkers(in: layer, tracks: tracks).count == 1)
    }

    @Test func eligibilityUsesTheReplacedFilesOffset() throws {
        var project = EditingProject.empty
        let song = audioAsset()
        let ids = add(song, to: &project)
        let index = try #require(project.timelines[0].layers.firstIndex { $0.id == ids.layerID })
        project.timelines[0].layers[index].clips[0].trimStart = t(0.6)
        project.timelines[0].layers[index].clips[0].trimEnd = t(0.9)
        let tracks = [song.id: sample]
        #expect(!project.layerHasBeats(project.timelines[0].layers[index], tracks: tracks))

        // File time is now 0.2...0.5 s later, which reaches the beat at 1.0 s.
        project.setAlignmentOffset(t(0.2), forAsset: song.id)

        #expect(project.layerHasBeats(project.timelines[0].layers[index], tracks: tracks))
    }

    @Test func aClipWhoseAssetIsGoneIsNotOffered() throws {
        var project = EditingProject.empty
        let song = audioAsset()
        let ids = add(song, to: &project)
        project.clips.removeAll()
        let layer = try #require(project.timelines[0].layer(id: ids.layerID))

        #expect(!project.layerHasBeats(layer, tracks: [song.id: sample]))
        #expect(project.beatMarkers(in: layer, tracks: [song.id: sample]).isEmpty)
    }

    @Test func hasBeatsMatchesTheBeatsInTheRange() {
        let bounds: [CMTime] = [-1, 0, 0.25, 0.5, 0.75, 1, 2, 2.0005, 3].map { t($0) }
        for start in bounds {
            for end in bounds {
                let found = sample.hasBeats(from: start, to: end)
                #expect(found == !sample.beats(from: start, to: end).isEmpty, "\(start.seconds)..<\(end.seconds)")
            }
        }
    }

    @Test func deletingALayerRemovesItFromTheChoices() throws {
        var project = EditingProject.empty
        let song = audioAsset("song.wav"), other = audioAsset("other.wav")
        let first = add(song, to: &project)
        let second = add(other, to: &project)
        let tracks = [song.id: sample, other.id: sample]
        #expect(Set(project.beatLayers(in: project.timelines[0], tracks: tracks).map(\.id)) == [first.layerID, second.layerID])

        project.timelines[0].layers.removeAll { $0.id == first.layerID }

        #expect(project.beatLayers(in: project.timelines[0], tracks: tracks).map(\.id) == [second.layerID])
    }
}

// MARK: - Analysis queue and saving

private func writeClickFile(seconds: Double = 12) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "amv-beats-\(UUID().uuidString).wav")
    let rate = 44_100.0
    let samples = clickTrack(seconds: seconds, interval: 0.5, first: 0.1, sampleRate: rate)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
    return url
}

@Suite struct SampleReadingTests {
    /// Blocking reads used to run on the cooperative pool, where more of
    /// them than there are cores stalled every task in the process.
    @Test func moreReadsThanCoresAtOnceAllFinish() async throws {
        let url = try writeClickFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let count = ProcessInfo.processInfo.activeProcessorCount * 2

        let finished = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<count {
                group.addTask { !(try await BeatDetector.detect(url: url)).isEmpty }
            }
            return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }

        #expect(finished == count)
    }

    @Test func cancellingStopsTheRead() async throws {
        let task = Task {
            try await SampleReading.run { isCancelled in
                while !isCancelled() { usleep(1_000) }
                throw CancellationError()
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@MainActor
@Suite struct BeatAnalysisQueueTests {
    /// What the project has accepted for the file: results name it.
    private let stamp = FileStamp(byteCount: 100, modified: 1)
    private let otherStamp = FileStamp(byteCount: 200, modified: 2)

    private func project(url: URL, hasAudio: Bool, stamp: FileStamp? = nil, onMusic: Bool = true) -> EditingProject {
        var project = EditingProject.empty
        project.clips = [MediaClip(
            name: url.lastPathComponent, kind: .audio, url: url,
            duration: CMTime(seconds: 12, preferredTimescale: 600), frameRate: 0,
            colorSpace: .rec709, codecName: "Test", hasAudio: hasAudio,
            acceptedStamp: stamp ?? FileStamp(url: url) ?? self.stamp
        )]
        if onMusic { project.putOnMusicLayer(project.clips.map(\.id)) }
        return project
    }

    private func waitForBeats(_ analysis: AssetAnalysis) async throws {
        for _ in 0..<2000 {
            if analysis.progress.isEmpty && analysis.beats.count + analysis.beatFailures.count >= 1 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("beat analysis did not finish")
    }

    @Test func clipsWithAudioGetBeatsAndTheyAreUnsavedUntilMarked() async throws {
        let url = try writeClickFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let project = project(url: url, hasAudio: true)
        let id = project.clips[0].id
        let analysis = AssetAnalysis()

        analysis.update(with: project)
        try await waitForBeats(analysis)

        let track = try #require(analysis.beats[id])
        #expect(abs(track.beatsPerMinute - 120) < 3)
        #expect(Set(analysis.unsavedBeats.keys) == [id])
        analysis.markSaved(analysis.unsavedResults())
        #expect(analysis.unsavedBeats.isEmpty)
        #expect(analysis.beats[id] != nil)
    }

    @Test func clipsWithoutAudioAreNotAnalyzedForBeats() async throws {
        let url = try writeClickFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let silent = project(url: url, hasAudio: false)
        let analysis = AssetAnalysis()

        analysis.update(with: silent)
        for _ in 0..<2000 where !analysis.progress.isEmpty { try await Task.sleep(for: .milliseconds(5)) }

        #expect(analysis.beats.isEmpty)
        #expect(analysis.beatFailures.isEmpty)
    }

    @Test func onlySoundOnAMusicLayerIsAnalyzedForBeats() async throws {
        let url = try writeClickFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        var project = project(url: url, hasAudio: true, onMusic: false)
        let id = project.clips[0].id
        let analysis = AssetAnalysis()
        // In the library, and then on a Sound layer: neither is music.
        analysis.update(with: project)
        project.placeAsset(id, intoTimeline: project.rootTimelineID)
        analysis.update(with: project)
        for _ in 0..<2000 where !analysis.progress.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(analysis.beats.isEmpty)

        project.timelines[0].layers[0].kind = .music
        analysis.update(with: project)
        try await waitForBeats(analysis)

        #expect(analysis.beats[id] != nil)
    }

    @Test func savedBeatsAreNotFoundAgain() async throws {
        let url = try writeClickFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let project = project(url: url, hasAudio: true)
        let id = project.clips[0].id
        let analysis = AssetAnalysis()
        analysis.reset(beats: [id: .none()], sources: AnalysisSources(beats: [id: project.clips[0].acceptedStamp!]))

        analysis.update(with: project)

        for _ in 0..<2000 where !analysis.progress.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(analysis.beats[id] == BeatTrack.none())
        #expect(analysis.unsavedBeats.isEmpty)
    }

    @Test func beatsAreFoundAgainWhenTheAssetPointsAtAnotherFile() async throws {
        // The old file is missing; the new one is a real click track, since a
        // missing file waits for its file rather than being analyzed.
        let folder = FileManager.default.temporaryDirectory
        let newURL = try writeClickFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: newURL) }
        var project = project(url: folder.appending(path: "amv-old-\(UUID().uuidString).wav"), hasAudio: true)
        project.clips[0].referenceForgotten = true
        let id = project.clips[0].id
        let analysis = AssetAnalysis()
        analysis.reset(beats: [id: .none()], sources: AnalysisSources(beats: [id: stamp]))
        analysis.update(with: project)
        #expect(analysis.beats[id] == BeatTrack.none())
        #expect(analysis.progress.isEmpty)

        project.clips[0].url = newURL
        project.clips[0].acceptedStamp = FileStamp(url: newURL)
        analysis.update(with: project)

        #expect(analysis.beats[id] == nil)
        #expect(analysis.discardedBeats == [id])
        #expect(analysis.progress[id] != nil)
        try await waitForBeats(analysis)
        let track = try #require(analysis.beats[id])
        #expect(track != BeatTrack.none())
        #expect(analysis.stages.isEmpty)
    }

    @Test func beatsAreDroppedWhenTheFileLosesItsSound() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-silent-\(UUID().uuidString).wav")
        var project = project(url: url, hasAudio: true)
        project.clips[0].referenceForgotten = true
        let id = project.clips[0].id
        let analysis = AssetAnalysis()
        analysis.reset(beats: [id: .none()], sources: AnalysisSources(beats: [id: stamp]))
        analysis.update(with: project)

        project.clips[0].hasAudio = false
        analysis.update(with: project)

        #expect(analysis.beats[id] == nil)
        #expect(analysis.discardedBeats == [id])
        analysis.markSaved(analysis.unsavedResults())
        #expect(analysis.discardedBeats.isEmpty)
    }
}

@Suite struct BeatStorageTests {
    private func makePackage() throws -> (root: URL, package: URL, project: EditingProject, assetID: UUID) {
        let root = FileManager.default.temporaryDirectory.appending(path: "amv-beat-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appending(path: "song.wav")
        try Data("not really audio".utf8).write(to: media)
        var project = EditingProject.empty
        let asset = MediaClip(
            name: "song.wav", kind: .audio, url: media,
            duration: CMTime(seconds: 10, preferredTimescale: 600), frameRate: 0,
            colorSpace: .rec709, codecName: "Stub", hasAudio: true
        )
        _ = project.importClip(asset, intoTimeline: project.rootTimelineID)
        return (root, root.appending(path: "Test.amv", directoryHint: .isDirectory), project, asset.id)
    }

    private func mediaStamp(in root: URL) -> FileStamp { FileStamp(url: root.appending(path: "song.wav"))! }

    private let stubImporter: @Sendable (URL) async throws -> MediaClip = { url in
        MediaClip(
            name: url.lastPathComponent, kind: .audio, url: url,
            duration: CMTime(seconds: 10, preferredTimescale: 600), frameRate: 0,
            colorSpace: .rec709, codecName: "Stub", hasAudio: true
        )
    }

    @Test func beatsAreSavedInReferenceAndLoadedBack() async throws {
        let (root, package, project, assetID) = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = try BeatTrack(timescale: 1000, times: [100, 600, 1100], beatsPerMinute: 120)

        try await ProjectStore.save(
            project, to: package, beats: [assetID: track], sources: AnalysisSources(beats: [assetID: mediaStamp(in: root)])
        )

        let file = ProjectStore.referenceFolder(for: assetID, in: package).appending(path: ProjectStore.beatFileName)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let loaded = try await ProjectStore.load(from: package, importMedia: stubImporter)
        #expect(loaded.beats[assetID]?.times == track.times)
    }

    @Test func anEmptyResultIsSavedSoTheAudioIsNotAnalyzedAgain() async throws {
        let (root, package, project, assetID) = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        try await ProjectStore.save(
            project, to: package, beats: [assetID: .none()], sources: AnalysisSources(beats: [assetID: mediaStamp(in: root)])
        )

        let loaded = try await ProjectStore.load(from: package, importMedia: stubImporter)
        #expect(try #require(loaded.beats[assetID]).isEmpty)
    }

    @Test func discardedBeatsAreDeletedWhenSaving() async throws {
        let (root, package, project, assetID) = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        try await ProjectStore.save(project, to: package, beats: [assetID: .none()])

        try await ProjectStore.save(project, to: package, discardingBeats: [assetID])

        #expect(ProjectStore.readBeats(for: assetID, in: package) == nil)
    }

    @Test func beatsForUnknownAssetsAreNotWritten() async throws {
        let (root, package, project, _) = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let stray = UUID()

        try await ProjectStore.save(project, to: package, beats: [stray: .none()])

        #expect(!FileManager.default.fileExists(atPath: ProjectStore.referenceFolder(for: stray, in: package).path))
    }

    @Test func aDamagedBeatFileJustMeansNotAnalyzed() async throws {
        let (root, package, project, assetID) = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        try await ProjectStore.save(project, to: package, beats: [assetID: .none()])
        let file = ProjectStore.referenceFolder(for: assetID, in: package).appending(path: ProjectStore.beatFileName)
        try Data("garbage".utf8).write(to: file)

        let loaded = try await ProjectStore.load(from: package, importMedia: stubImporter)

        #expect(loaded.beats[assetID] == nil)
    }
}
