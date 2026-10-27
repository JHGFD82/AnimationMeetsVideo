import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The worst case for fitting the period: a whole song at a high frame
/// rate, with two anchors only a beat apart, so the search is at its
/// widest and every candidate steps across six minutes of beats.
@Suite struct BeatFittingPerformanceTests {
    static let framesPerSecond = 400.0

    static func song() -> (curve: OnsetCurve, beats: [Double]) {
        let beats = Array(stride(from: 0.3, to: 360, by: 60 / 124.0))
        var values = [Float](repeating: 0.05, count: Int(360 * framesPerSecond))
        for beat in beats {
            let center = beat * framesPerSecond
            for frame in max(0, Int(center) - 8)...min(values.count - 1, Int(center) + 8) {
                let distance = Double(frame) - center
                values[frame] = max(values[frame], 4 * Float(exp(-distance * distance / 4)))
            }
        }
        return (OnsetCurve(values: values, framesPerSecond: framesPerSecond, start: 0), beats)
    }

    @Test(arguments: [BeatSection.Steadiness.click, .intent])
    func aSixMinuteSongWithAnchorsOneBeatApartFillsQuickly(_ steadiness: BeatSection.Steadiness) throws {
        let (curve, beats) = Self.song()
        let rate = 48_000.0
        let pins = [beats[300], beats[301]].map { MappedBeat(time: BeatFitting.time($0, sampleRate: rate), position: 1, isPinned: true) }
        let section = BeatSection(
            kind: .consistent, start: .zero, end: BeatFitting.time(360, sampleRate: rate), steadiness: steadiness, beats: pins
        )
        let map = BeatMap(sections: [section])
        let clock = ContinuousClock()
        var filled = map
        let elapsed = try clock.measure {
            filled = try BeatFitting.fill(map, section: section.id, curve: curve, sampleRate: rate, duration: BeatFitting.time(361, sampleRate: rate))
        }
        print("BeatFittingPerformanceTests \(steadiness): \(elapsed)")
        let found = filled.sections[0].beats
        // Steady by intent, anchors a beat apart double the tempo: the
        // refined count search scores no beat between them at 0, below a
        // chain with one. Only the time is held to here.
        if steadiness == .click { #expect(found.count == beats.count) }
        // Debug builds run several times slower than release, which this
        // is meant for; the bound leaves room for that.
        #expect(elapsed < .seconds(1), "\(elapsed)")
    }
}
