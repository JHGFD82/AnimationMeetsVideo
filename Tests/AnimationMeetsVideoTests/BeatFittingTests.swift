import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private let rate = 48_000.0
private let framesPerSecond = BeatDetector.sampleRate / 64

private func time(_ seconds: Double) -> CMTime { BeatFitting.time(seconds, sampleRate: rate) }

/// A curve with a sharp onset at each beat, and softer ones halfway
/// between (an off-beat hi-hat), so a wrong count or a drifting grid
/// lands on weaker onsets.
private func curve(beats: [Double], seconds: Double, offbeats: Bool = true) -> OnsetCurve {
    var values = [Float](repeating: 0.05, count: Int(seconds * framesPerSecond))
    func bump(at time: Double, height: Float) {
        let center = time * framesPerSecond
        for frame in max(0, Int(center) - 6)...min(values.count - 1, Int(center) + 6) {
            let distance = Double(frame) - center
            values[frame] = max(values[frame], height * Float(exp(-distance * distance / 2)))
        }
    }
    for beat in beats { bump(at: beat, height: 4) }
    if offbeats {
        for (a, b) in zip(beats, beats.dropFirst()) { bump(at: (a + b) / 2, height: 1.5) }
    }
    return OnsetCurve(values: values, framesPerSecond: framesPerSecond, start: 0)
}

private func steadyBeats(bpm: Double, from start: Double, to end: Double) -> [Double] {
    Array(stride(from: start, to: end, by: 60 / bpm))
}

/// The largest distance, in seconds, from each found beat to the nearest true one.
private func worstError(_ found: [MappedBeat], _ truth: [Double]) -> Double {
    found.map { beat in truth.map { abs($0 - beat.time.seconds) }.min() ?? .infinity }.max() ?? .infinity
}

private func section(_ kind: BeatSection.Kind, _ start: Double, _ end: Double, pins: [(Double, Int)] = [], steadiness: BeatSection.Steadiness = .click) -> BeatSection {
    BeatSection(
        kind: kind, start: time(start), end: time(end), steadiness: steadiness,
        beats: pins.map { MappedBeat(time: time($0.0), position: $0.1, isPinned: true) }
    )
}

@Suite struct BeatFittingTests {
    @Test func aClickTrackIsAnExactGridFromTwoAnchors() throws {
        let truth = steadyBeats(bpm: 123.4, from: 0.37, to: 40)
        let onsets = curve(beats: truth, seconds: 40)
        // Anchors 32 beats apart, both downbeats.
        let input = section(.consistent, 0, 40, pins: [(truth[10], 1), (truth[42], 1)])
        let (filled, period) = try BeatFitting.fillConsistent(input, curve: onsets, sampleRate: rate)

        #expect(abs(period - 60 / 123.4) < 1e-6)
        #expect(filled.beats.count == truth.count)
        #expect(worstError(filled.beats, truth) < 1.0 / rate)
        #expect(filled.isConfirmed)
    }

    @Test func theAnchorsPlacesInTheMeasureSettleTheCount() throws {
        // With no off-beats a count one off scores nearly as well, so the
        // measure decides.
        let truth = steadyBeats(bpm: 100, from: 0.5, to: 60)
        let onsets = curve(beats: truth, seconds: 60, offbeats: false)
        let input = section(.consistent, 0, 60, pins: [(truth[4], 1), (truth[84], 1)])
        let (filled, _) = try BeatFitting.fillConsistent(input, curve: onsets, sampleRate: rate)
        #expect(worstError(filled.beats, truth) < 0.001)
    }

    @Test func beatsWithoutAHitOnThemStillReachTheEndsOfTheSong() throws {
        // Most beats have no hit of their own (a held chord, a vocal), only
        // something happening between them, and the song has a silent tail.
        let truth = steadyBeats(bpm: 100, from: 0.3, to: 60)
        let hits = truth.enumerated().filter { $0.offset.isMultiple(of: 8) }.map(\.element)
        var onsets = curve(beats: hits, seconds: 66, offbeats: false)
        for (a, b) in zip(truth, truth.dropFirst()) {
            let frame = Int((a + 0.37 * (b - a)) * framesPerSecond)
            onsets.values[frame] = 1.2
        }
        let input = section(.consistent, 0, 66, pins: [(truth[24], 1), (truth[40], 1)])
        let (filled, _) = try BeatFitting.fillConsistent(input, curve: onsets, sampleRate: rate)
        let first = try #require(filled.beats.first?.time.seconds)
        let last = try #require(filled.beats.last?.time.seconds)
        #expect(abs(first - truth[0]) < 0.001)
        // Through the music, but not two measures into the silence after it.
        #expect(last >= truth[truth.count - 1] - 0.001)
        #expect(last < 60 + 8 * 0.6)
    }

    @Test func aTypedTempoOverridesTheCount() throws {
        let truth = steadyBeats(bpm: 90, from: 0.2, to: 20)
        let onsets = curve(beats: truth, seconds: 20)
        let input = section(.consistent, 0, 20, pins: [(truth[2], 1), (truth[18], 1)])
        let (filled, period) = try BeatFitting.fillConsistent(input, curve: onsets, sampleRate: rate, tempo: 180)
        #expect(abs(period - 60.0 / 180) < 1e-6)
        #expect(filled.beats.count == 2 * truth.count - 1)
    }

    @Test func aDriftingPerformanceIsFollowedOnlyWhenSteadyByIntent() throws {
        // Meant to be 96 BPM, wandering 3% either way over eight bars.
        var truth: [Double] = [0.4]
        while truth.last! < 45 {
            let drift = 1 + 0.03 * sin(truth.last! / 20 * 2 * .pi)
            truth.append(truth.last! + 60 / 96 * drift)
        }
        let onsets = curve(beats: truth, seconds: 46)
        let pins = [(truth[8], 1), (truth[40], 1)]

        let (click, _) = try BeatFitting.fillConsistent(section(.consistent, 0, 45, pins: pins), curve: onsets, sampleRate: rate)
        let (intent, _) = try BeatFitting.fillConsistent(
            section(.consistent, 0, 45, pins: pins, steadiness: .intent), curve: onsets, sampleRate: rate
        )
        #expect(worstError(click.beats, truth) > 0.05)
        let intentError = worstError(intent.beats, truth)
        #expect(intentError < 0.004, "\(intentError)")
    }

    @Test func aTwoAnchorSectionNeedsBothAnchors() {
        let input = section(.consistent, 0, 10, pins: [(1, 1)])
        #expect(throws: BeatFitting.Failure.needsTwoAnchors) {
            try BeatFitting.fillConsistent(input, curve: curve(beats: [1], seconds: 10), sampleRate: rate)
        }
    }

    @Test func reanalyzingKeepsAMovedBeatAndBendsTheRestToIt() throws {
        let truth = steadyBeats(bpm: 120, from: 0.25, to: 20)
        let onsets = curve(beats: truth, seconds: 20)
        var (filled, _) = try BeatFitting.fillConsistent(
            section(.consistent, 0, 20, pins: [(truth[2], 1), (truth[34], 1)]), curve: onsets, sampleRate: rate
        )
        // The person moves beat 20 a little late by hand.
        let index = try #require(filled.beats.firstIndex { abs($0.time.seconds - truth[20]) < 0.001 })
        filled.beats[index].time = time(truth[20] + 0.01)
        filled.beats[index].isPinned = true

        let (again, _) = try BeatFitting.fillConsistent(filled, curve: onsets, sampleRate: rate)
        let moved = again.beats.first { $0.isPinned && abs($0.time.seconds - (truth[20] + 0.01)) < 1e-6 }
        #expect(moved != nil)
        #expect(again.beats.count == filled.beats.count)
        // Between beat 2 and the moved one, beats spread out to meet it.
        let between = again.beats.first { abs($0.time.seconds - truth[11]) < 0.02 }
        #expect(between.map { $0.time.seconds > truth[11] } == true)
    }

    @Test func aRampIsFoundBetweenTwoFilledSections() throws {
        // 100 BPM, an uneven speed-up over about eight seconds, then 130.
        var truth = steadyBeats(bpm: 100, from: 0.3, to: 20)
        let rampStart = truth.last! + 0.6
        var position = rampStart
        let rampBeats = 15
        for step in 0..<rampBeats {
            truth.append(position)
            // Eased: most of the change comes late.
            let progress = pow(Double(step + 1) / Double(rampBeats), 2)
            position += 60 / (100 + 30 * progress)
        }
        let afterStart = position
        truth += steadyBeats(bpm: 130, from: afterStart, to: afterStart + 20)
        let onsets = curve(beats: truth, seconds: afterStart + 21)

        let firstEnd = truth[truth.firstIndex { $0 >= 20 }! - 1] + 0.3
        var map = BeatMap(sections: [
            section(.consistent, 0, firstEnd, pins: [(truth[2], 1), (truth[30], 1)]),
            section(.ramp, firstEnd, afterStart - 0.2),
            section(.consistent, afterStart - 0.2, afterStart + 20, pins: [(afterStart + 60 / 130 * 4, 1), (afterStart + 60 / 130 * 36, 1)]),
        ], usesSections: true)
        let duration = time(afterStart + 21)
        map = try BeatFitting.fill(map, section: map.sections[0].id, curve: onsets, sampleRate: rate, duration: duration)
        map = try BeatFitting.fill(map, section: map.sections[2].id, curve: onsets, sampleRate: rate, duration: duration)
        map = try BeatFitting.fill(map, section: map.sections[1].id, curve: onsets, sampleRate: rate, duration: duration)

        let ramp = map.sections[1]
        let rampTruth = Array(truth[truth.firstIndex { $0 >= rampStart - 0.01 }!...].prefix(rampBeats))
        #expect(ramp.beats.count == rampTruth.count)
        #expect(worstError(ramp.beats, truth) < 0.004)
    }

    @Test func aRampAtTheStartTakesItsTempoFromAMarkedMeasure() throws {
        // Slowing into the song: 140 down to 110 over six beats, then 110.
        var truth: [Double] = []
        var position = 0.5
        for step in 0..<6 {
            truth.append(position)
            position += 60 / (140 - 30 * Double(step) / 5)
        }
        let steadyStart = position
        truth += steadyBeats(bpm: 110, from: steadyStart, to: steadyStart + 15)
        let onsets = curve(beats: truth, seconds: steadyStart + 16)
        let duration = time(steadyStart + 16)
        var map = BeatMap(sections: [
            // The measure marked at the open start: four beats.
            section(.ramp, 0, steadyStart - 0.1, pins: truth.prefix(4).enumerated().map { ($1, $0 + 1) }),
            section(.consistent, steadyStart - 0.1, steadyStart + 15, pins: [(truth[6], 1), (truth[22], 1)]),
        ], usesSections: true)
        #expect(throws: BeatFitting.Failure.self) {
            try BeatFitting.fill(map, section: map.sections[0].id, curve: onsets, sampleRate: rate, duration: duration)
        }
        map = try BeatFitting.fill(map, section: map.sections[1].id, curve: onsets, sampleRate: rate, duration: duration)
        map = try BeatFitting.fill(map, section: map.sections[0].id, curve: onsets, sampleRate: rate, duration: duration)
        #expect(map.sections[0].beats.count == 6)
        #expect(worstError(map.sections[0].beats, truth) < 0.004)
    }

    @Test func refinedBeatsLandOnTheClicksOfADecodedFile() async throws {
        let interval = 60 / 137.0
        let url = try writeClickFile(seconds: 20, interval: interval, first: 0.23)
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = try await BeatMatchAudio.load(url: url, alignment: .zero)
        #expect(audio.sampleRate == 44_100)
        #expect(abs(audio.duration - 20) < 0.01)
        #expect(abs(audio.start) < 1e-9)

        let truth = Array(stride(from: 0.23, to: 20, by: interval))
        let input = section(.consistent, 0, 20, pins: [(truth[4], 1), (truth[36], 1)], steadiness: .intent)
        let (filled, _) = try BeatFitting.fillConsistent(input, curve: audio.curve, sampleRate: audio.sampleRate)
        #expect(filled.beats.count == truth.count)
        // The onset curve's frames are 2.9 ms apart.
        let error = worstError(filled.beats, truth)
        #expect(error < 0.004, "\(error)")
    }

    @Test func positionsCarryOnIntoASectionWithoutPins() throws {
        var map = BeatMap(sections: [
            BeatSection(kind: .consistent, start: .zero, end: time(3), beatsPerMeasure: 3, isConfirmed: true, beats: [
                MappedBeat(time: time(0), position: 1, isPinned: true), MappedBeat(time: time(1)), MappedBeat(time: time(2)),
                MappedBeat(time: time(2.5)),
            ]),
            BeatSection(kind: .ramp, start: time(3), end: time(5), beatsPerMeasure: 4, isConfirmed: true, beats: [
                MappedBeat(time: time(3)), MappedBeat(time: time(4)),
            ]),
        ])
        map.recountPositions()
        let positions: [Int] = map.confirmedBeats.map(\.position)
        #expect(positions == [1, 2, 3, 1, 2, 3])
    }

    @Test func fillingMovesTheEdgesOntoTheBeatsAndKeepsNeighboursJoined() throws {
        let truth = steadyBeats(bpm: 120, from: 1.1, to: 30)
        let onsets = curve(beats: truth, seconds: 31)
        var map = BeatMap(sections: [
            section(.consistent, 0.8, 10.2, pins: [(truth[1], 1), (truth[17], 1)]),
            section(.ramp, 10.2, 14),
        ], usesSections: true)
        map = try BeatFitting.fill(map, section: map.sections[0].id, curve: onsets, sampleRate: rate, duration: time(31))
        let first = map.sections[0]
        #expect(first.start == first.beats.first?.time)
        // The beat after the last one, where the next section's first falls.
        let next = truth[first.beats.count]
        #expect(abs(first.end.seconds - next) < 1.0 / rate)
        #expect(map.sections[1].start == first.end)
    }
}
