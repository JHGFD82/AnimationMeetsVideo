import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Fills of fixed fixture curves, held to the beats recorded before
/// `BeatFitting` was reworked for speed (`BeatFittingGoldens`), so the
/// rework keeps what the fills find. To record them again, run with
/// `BEAT_GOLDEN_RECORD=<path to BeatFittingGoldens.swift>`.
@Suite struct BeatFittingGoldenTests {
    static let rate = 48_000.0
    static let framesPerSecond = BeatDetector.sampleRate / 64

    /// A fixture: a curve, a map, and which sections to fill in order.
    struct Fixture {
        var name: String
        var curve: OnsetCurve
        var map: BeatMap
        var duration: Double
    }

    private static func time(_ seconds: Double) -> CMTime { BeatFitting.time(seconds, sampleRate: rate) }

    /// Repeatable jitter: a linear congruential generator.
    struct Jitter {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// Onsets at each beat, softer ones between, a low noise floor.
    static func curve(beats: [Double], seconds: Double, seed: UInt64 = 1, offbeats: Bool = true) -> OnsetCurve {
        var noise = Jitter(state: seed)
        var values = (0..<Int(seconds * framesPerSecond)).map { _ in Float(0.02 + 0.1 * noise.next()) }
        func bump(at time: Double, height: Float) {
            let center = time * framesPerSecond
            guard center > 6, Int(center) + 6 < values.count else { return }
            for frame in (Int(center) - 6)...(Int(center) + 6) {
                let distance = Double(frame) - center
                values[frame] = max(values[frame], height * Float(exp(-distance * distance / 2)))
            }
        }
        for beat in beats { bump(at: beat, height: Float(3 + 2 * noise.next())) }
        if offbeats {
            for (a, b) in zip(beats, beats.dropFirst()) { bump(at: (a + b) / 2, height: Float(1 + noise.next())) }
        }
        return OnsetCurve(values: values, framesPerSecond: framesPerSecond, start: 0)
    }

    static func section(
        _ kind: BeatSection.Kind, _ start: Double, _ end: Double, pins: [(Double, Int)] = [], steadiness: BeatSection.Steadiness = .click
    ) -> BeatSection {
        BeatSection(
            kind: kind, start: time(start), end: time(end), steadiness: steadiness,
            beats: pins.map { MappedBeat(time: time($0.0), position: $0.1, isPinned: true) }
        )
    }

    static var fixtures: [Fixture] {
        var fixtures: [Fixture] = []

        let click = Array(stride(from: 0.31, to: 60, by: 0.5))
        fixtures.append(Fixture(
            name: "click120", curve: curve(beats: click, seconds: 61),
            map: BeatMap(sections: [section(.consistent, 0, 60, pins: [(click[8] + 0.003, 1), (click[100] - 0.002, 1)])]),
            duration: 61
        ))

        // Live drums: 96 BPM wandering 3% either way, each hit up to 8 ms off.
        var jitter = Jitter(state: 7)
        var drums: [Double] = [0.4]
        while drums.last! < 45 {
            let drift = 1 + 0.03 * sin(drums.last! / 20 * 2 * .pi)
            drums.append(drums.last! + 60 / 96 * drift)
        }
        let played = drums.map { $0 + 0.016 * (jitter.next() - 0.5) }
        fixtures.append(Fixture(
            name: "liveDrums", curve: curve(beats: played, seconds: 46, seed: 3),
            map: BeatMap(sections: [section(.consistent, 0, 45, pins: [(played[8], 1), (played[40], 1)], steadiness: .intent)]),
            duration: 46
        ))

        // 100 BPM, an even ramp up to 140 over twelve beats, then 140.
        var ramp = Array(stride(from: 0.3, to: 15, by: 0.6))
        let rampStart = ramp.last! + 0.6
        var position = rampStart
        for step in 0..<12 {
            ramp.append(position)
            position += 60 / (100 + 40 * Double(step + 1) / 12)
        }
        let afterStart = position
        ramp += Array(stride(from: afterStart, to: afterStart + 15, by: 60 / 140))
        let firstEnd = rampStart - 0.3
        fixtures.append(Fixture(
            name: "ramp100to140", curve: curve(beats: ramp, seconds: afterStart + 16, seed: 5),
            map: BeatMap(sections: [
                section(.consistent, 0, firstEnd, pins: [(ramp[2], 1), (ramp[18], 1)]),
                section(.ramp, firstEnd, afterStart - 0.2),
                section(.consistent, afterStart - 0.2, afterStart + 15, pins: [(afterStart + 60 / 140 * 4, 1), (afterStart + 60 / 140 * 28, 1)]),
            ], usesSections: true),
            duration: afterStart + 16
        ))

        // 112 BPM to 40 s, then 8 s of silence the section runs into.
        let song = Array(stride(from: 0.2, to: 40, by: 60 / 112))
        var silent = curve(beats: song, seconds: 48, seed: 9)
        for frame in Int(40.2 * framesPerSecond)..<silent.values.count { silent.values[frame] = 0 }
        fixtures.append(Fixture(
            name: "silentTail", curve: silent,
            map: BeatMap(sections: [section(.consistent, 0, 48, pins: [(song[12], 1), (song[44], 1)])]),
            duration: 48
        ))
        return fixtures
    }

    /// Fills every section of the fixture with pins, then the ramps, and
    /// gives every confirmed beat, in samples at `rate`.
    static func run(_ fixture: Fixture) throws -> [Int64] {
        var map = fixture.map
        let order = map.sections.filter { $0.kind == .consistent }.map(\.id) + map.sections.filter { $0.kind == .ramp }.map(\.id)
        for id in order {
            map = try BeatFitting.fill(map, section: id, curve: fixture.curve, sampleRate: rate, duration: time(fixture.duration))
        }
        return map.confirmedBeats.map { CMTimeConvertScale($0.time, timescale: Int32(rate), method: .roundHalfAwayFromZero).value }
    }

    @Test func fillsMatchTheRecordedBeats() throws {
        if let path = ProcessInfo.processInfo.environment["BEAT_GOLDEN_RECORD"] {
            var source = "// Recorded by BeatFittingGoldenTests: beats in samples at 48 kHz.\n\nenum BeatFittingGoldens {\n"
            source += "    static let beats: [String: [Int64]] = [\n"
            for fixture in Self.fixtures {
                let beats = try Self.run(fixture)
                source += "        \"\(fixture.name)\": [\n"
                for row in stride(from: 0, to: beats.count, by: 8) {
                    source += "            " + beats[row..<min(row + 8, beats.count)].map(String.init).joined(separator: ", ") + ",\n"
                }
                source += "        ],\n"
            }
            source += "    ]\n}\n"
            try source.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        for fixture in Self.fixtures {
            let recorded = try #require(BeatFittingGoldens.beats[fixture.name], "\(fixture.name) has no recording")
            let beats = try Self.run(fixture)
            #expect(beats.count == recorded.count, "\(fixture.name): \(beats.count) beats, recorded \(recorded.count)")
            // Within a millisecond of each.
            let worst = zip(beats, recorded).map { abs($0 - $1) }.max() ?? 0
            print("BeatFittingGoldenTests \(fixture.name): worst \(worst) samples")
            #expect(Double(worst) / Self.rate < 0.001, "\(fixture.name): \(Double(worst) / Self.rate * 1000) ms off")
        }
    }
}
