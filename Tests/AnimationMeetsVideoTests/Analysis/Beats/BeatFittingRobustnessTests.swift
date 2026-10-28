import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private let rate = 48_000.0

private func time(_ seconds: Double) -> CMTime { BeatFitting.time(seconds, sampleRate: rate) }

private func clickCurve(bpm: Double, seconds: Double, framesPerSecond: Double = BeatDetector.sampleRate / 64, from first: Double = 0.3) -> (OnsetCurve, [Double]) {
    let beats = Array(stride(from: first, to: seconds, by: 60 / bpm))
    var values = [Float](repeating: 0.05, count: Int(seconds * framesPerSecond))
    let width = max(1, Int(0.006 * framesPerSecond))
    for beat in beats {
        let center = beat * framesPerSecond
        for frame in max(0, Int(center) - 3 * width)...min(values.count - 1, Int(center) + 3 * width) {
            let distance = (Double(frame) - center) / Double(width)
            values[frame] = max(values[frame], 4 * Float(exp(-distance * distance / 2)))
        }
    }
    return (OnsetCurve(values: values, framesPerSecond: framesPerSecond, start: 0), beats)
}

/// A consistent section with these beats, in this order, as they are:
/// not normalized, so out-of-order and doubled pins reach the fill.
private func rawSection(_ start: Double, _ end: Double, pins: [(Double, Int)], steadiness: BeatSection.Steadiness = .click) -> BeatSection {
    var section = BeatSection(kind: .consistent, start: time(start), end: time(end), steadiness: steadiness)
    section.beats = pins.map { MappedBeat(time: time($0.0), position: $0.1, isPinned: true) }
    return section
}

private func worstError(_ found: [MappedBeat], _ truth: [Double]) -> Double {
    found.map { beat in truth.map { abs($0 - beat.time.seconds) }.min() ?? .infinity }.max() ?? .infinity
}

@Suite struct BeatFittingRobustnessTests {
    // MARK: Pins

    @Test func duplicatePinsFillAsOne() throws {
        let (curve, truth) = clickCurve(bpm: 120, seconds: 30)
        let section = rawSection(0, 30, pins: [(truth[4], 1), (truth[4], 1), (truth[4] + 1 / rate / 2, 1), (truth[36], 1)])
        let (filled, period) = try BeatFitting.fillConsistent(section, curve: curve, sampleRate: rate)
        #expect(abs(period - 0.5) < 1e-4)
        #expect(filled.beats.count == truth.count)
    }

    @Test func pinsOutOfOrderFillTheSame() throws {
        let (curve, truth) = clickCurve(bpm: 120, seconds: 30)
        let ordered = try BeatFitting.fillConsistent(rawSection(0, 30, pins: [(truth[4], 1), (truth[36], 1)]), curve: curve, sampleRate: rate)
        let reversed = try BeatFitting.fillConsistent(rawSection(0, 30, pins: [(truth[36], 1), (truth[4], 1)]), curve: curve, sampleRate: rate)
        #expect(ordered.section.beats.map(\.time) == reversed.section.beats.map(\.time))
    }

    @Test func pinsAllOnOneSampleNeedASecondAnchor() {
        let (curve, truth) = clickCurve(bpm: 120, seconds: 10)
        #expect(throws: BeatFitting.Failure.needsTwoAnchors) {
            try BeatFitting.fillConsistent(rawSection(0, 10, pins: [(truth[4], 1), (truth[4], 1)]), curve: curve, sampleRate: rate)
        }
    }

    @Test func onePinWithATempoFillsTheSection() throws {
        let (curve, truth) = clickCurve(bpm: 100, seconds: 20)
        let (filled, period) = try BeatFitting.fillConsistent(rawSection(0, 20, pins: [(truth[10], 1)]), curve: curve, sampleRate: rate, tempo: 100)
        #expect(abs(period - 0.6) < 1e-9)
        #expect(filled.beats.count == truth.count)
        #expect(worstError(filled.beats, truth) < 0.001)
    }

    @Test func anUnusableTypedTempoNeedsAnchors() {
        let (curve, truth) = clickCurve(bpm: 100, seconds: 20)
        for tempo in [0, -10, Double.nan, .infinity] {
            #expect(throws: BeatFitting.Failure.needsTwoAnchors) {
                try BeatFitting.fillConsistent(rawSection(0, 20, pins: [(truth[10], 1)]), curve: curve, sampleRate: rate, tempo: tempo)
            }
        }
    }

    @Test func aSectionShorterThanTwoBeatsIsTooShort() {
        let (curve, _) = clickCurve(bpm: 60, seconds: 10)
        // One beat long, at a typed tempo and from two anchors.
        #expect(throws: BeatFitting.Failure.tooShort) {
            try BeatFitting.fillConsistent(rawSection(2.1, 2.9, pins: [(2.3, 1)]), curve: curve, sampleRate: rate, tempo: 60)
        }
        #expect(throws: BeatFitting.Failure.tooShort) {
            // Too short to estimate from, so the anchors' gap is one beat.
            try BeatFitting.fillConsistent(rawSection(2.2, 3.1, pins: [(2.3, 1), (2.9, 1)]), curve: curve, sampleRate: rate)
        }
    }

    // MARK: Curves

    @Test(arguments: [50.0, 100.0, 400.0])
    func otherFrameRatesFill(_ framesPerSecond: Double) throws {
        let (curve, truth) = clickCurve(bpm: 110, seconds: 40, framesPerSecond: framesPerSecond)
        for steadiness in [BeatSection.Steadiness.click, .intent] {
            let section = rawSection(0, 40, pins: [(truth[8], 1), (truth[40], 1)], steadiness: steadiness)
            let (filled, period) = try BeatFitting.fillConsistent(section, curve: curve, sampleRate: rate)
            #expect(abs(period - 60 / 110) < 0.002, "\(framesPerSecond) fps")
            #expect(filled.beats.count == truth.count, "\(framesPerSecond) fps")
            #expect(worstError(filled.beats, truth) < 2 / framesPerSecond + 0.002, "\(framesPerSecond) fps")
        }
    }

    @Test func aSilentCurveFillsOnTheAnchorsGrid() throws {
        let curve = OnsetCurve(values: [Float](repeating: 0, count: 20 * 345), framesPerSecond: 345, start: 0)
        for steadiness in [BeatSection.Steadiness.click, .intent] {
            let section = rawSection(0, 20, pins: [(4, 1), (6, 1)], steadiness: steadiness)
            let (filled, period) = try BeatFitting.fillConsistent(section, curve: curve, sampleRate: rate)
            #expect(period > 0 && period.isFinite)
            #expect(filled.beats.allSatisfy { $0.time.isNumeric })
        }
        let empty = OnsetCurve(values: [], framesPerSecond: 345, start: 0)
        _ = try BeatFitting.fillConsistent(rawSection(0, 20, pins: [(4, 1), (6, 1)]), curve: empty, sampleRate: rate)
        #expect(try BeatFitting.estimatedPeriod(curve: empty, from: 0, to: 20) == nil)
    }

    @Test func timesThatArentNumbersAreInvalid() {
        #expect(!BeatFitting.time(.nan, sampleRate: rate).isValid)
        #expect(!BeatFitting.time(.infinity, sampleRate: rate).isValid)
        #expect(!BeatFitting.time(1e300, sampleRate: rate).isValid)
        #expect(BeatFitting.time(1.5, sampleRate: .nan).isNumeric)
    }

    @Test func pinsOnOneSampleDoNotSplitEveryBeatIntoItsOwnRun() {
        let runs = BeatFitting.measureRuns([1, 1, 1.5, 2, 2.5, 6, 6.5], sampleRate: rate)
        #expect(runs.map(\.count) == [5, 2])
    }

    // MARK: Equivalence

    @Test func dilatedStrengthIsThePeaksStrength() {
        var noise = BeatFittingGoldenTests.Jitter(state: 11)
        let values = (0..<2000).map { _ in Float(noise.next() * 3) }
        for framesPerSecond in [100.0, 344.53125, 400.0, 1000.0] {
            let curve = OnsetCurve(values: values, framesPerSecond: framesPerSecond, start: 0)
            for reach in [1.0, 1.4, 2.0, 2.067, 2.4, 6.0, 7.5] {
                for _ in 0..<300 {
                    let frame = noise.next() * 2100 - 50
                    #expect(curve.strength(near: frame, reach: reach) == curve.peak(near: frame, reach: reach).strength)
                }
            }
        }
    }

    /// The period search as it was, scanning every step, with the beats
    /// placed by multiplying as the search now does.
    private func linearlyFittedPeriod(near period: Double, pins: [Double], from start: Double, to end: Double, curve: OnsetCurve) -> Double {
        let first = pins[0], last = pins[pins.count - 1]
        let span = max(last - first, period)
        let reach = period * (2 * BeatFitting.anchorUncertainty / span).clamped(between: 0.0005, and: 0.03)
        let farthest = max((first - start) / period, (end - last) / period, 1)
        let steps = min(4000, max(1, Int((reach / (0.001 / farthest)).rounded(.up))))
        let window = max(1, 0.006 * curve.framesPerSecond)
        func strength(_ seconds: Double) -> Double { Double(curve.peak(near: curve.frame(atSeconds: seconds), reach: window).strength) }
        func score(_ candidate: Double) -> Double {
            var total = 0.0, points = 0, k = 1.0
            while first - k * candidate >= start { total += strength(first - k * candidate); points += 1; k += 1 }
            k = 1
            while last + k * candidate < end { total += strength(last + k * candidate); points += 1; k += 1 }
            return points > 0 ? total / Double(points) : 0
        }
        var rough = period, roughScore = score(period)
        for index in -steps...steps where index != 0 {
            let candidate = period + reach * Double(index) / Double(steps)
            let value = score(candidate)
            if value > roughScore { rough = candidate; roughScore = value }
        }
        var numerator = 0.0, denominator = 0.0
        func fit(from anchor: Double, direction: Double, while inside: (Double) -> Bool) {
            var k = 1.0
            while inside(anchor + direction * k * rough) {
                let found = curve.peak(near: curve.frame(atSeconds: anchor + direction * k * rough), reach: window)
                if found.strength >= BeatFitting.weakOnset {
                    numerator += direction * k * (curve.seconds(atFrame: found.frame) - anchor)
                    denominator += k * k
                }
                k += 1
            }
        }
        fit(from: first, direction: -1) { $0 >= start }
        fit(from: last, direction: 1) { $0 < end }
        guard denominator > 0 else { return rough }
        return (numerator / denominator).clamped(between: period - reach, and: period + reach)
    }

    @Test func theBoundedPeriodSearchFindsWhatScanningEveryStepDoes() throws {
        var noise = BeatFittingGoldenTests.Jitter(state: 5)
        for fixture in BeatFittingGoldenTests.fixtures {
            for _ in 0..<6 {
                let start = noise.next() * 3, end = 15 + noise.next() * 30
                let first = start + 2 + noise.next() * 5
                let period = 0.4 + noise.next() * 0.3
                let pins = [first, first + period * Double(1 + Int(noise.next() * 30))]
                let guess = period * (1 + 0.01 * (noise.next() - 0.5))
                let found = try BeatFitting.fittedPeriod(near: guess, pins: pins, from: start, to: end, curve: fixture.curve)
                let scanned = linearlyFittedPeriod(near: guess, pins: pins, from: start, to: end, curve: fixture.curve)
                #expect(found == scanned, "\(fixture.name): \(found) against \(scanned)")
            }
        }
    }

    // MARK: Reports and snapping

    @Test func theReportSaysWhatTheFillDid() throws {
        let fixture = try #require(BeatFittingGoldenTests.fixtures.first { $0.name == "silentTail" })
        let id = fixture.map.sections[0].id
        let (map, report) = try BeatFitting.fillReporting(
            fixture.map, section: id, curve: fixture.curve, sampleRate: rate, duration: time(fixture.duration)
        )
        #expect(abs(try #require(report.beatsPerMinute) - 112) < 0.05)
        #expect(report.anchorCount == 32)
        #expect(!report.measureOverruledOnsets)
        #expect(report.beatCount == map.sections[0].beats.count)
        #expect(report.droppedSilentBeats == BeatFitting.silentBeats)
        #expect(report.edges == .moved)
        #expect(report.quietBeats == 0)

        // Filling again leaves the edges.
        let again = try BeatFitting.fillReporting(map, section: id, curve: fixture.curve, sampleRate: rate, duration: time(fixture.duration))
        #expect(again.report.edges == .unchanged)
    }

    @Test func aSnappedPinKeepsWhereItWasHeardAndCanBePutBack() throws {
        let (curve, truth) = clickCurve(bpm: 120, seconds: 30)
        let heard = truth[8] - 0.008
        let section = rawSection(0, 30, pins: [(heard, 1), (truth[40] + 0.008, 1)])
        var map = BeatMap(sections: [section])
        map = try BeatFitting.fill(map, section: section.id, curve: curve, sampleRate: rate, duration: time(30))
        let snapped = try #require(map.sections[0].beats.first { $0.heardTime == time(heard) })
        #expect(snapped.isPinned && snapped.time != time(heard))
        #expect(map.sections[0].beats.filter { $0.heardTime != nil }.count == 2)

        #expect(map.undoSnap(at: snapped.time) == time(heard))
        let restored = try #require(map.beat(at: time(heard)))
        #expect(!restored.snapsToOnset && restored.heardTime == nil)
        // Reanalyzing leaves it where it was put back.
        map = try BeatFitting.fill(map, section: section.id, curve: curve, sampleRate: rate, duration: time(30))
        #expect(map.beat(at: time(heard))?.isPinned == true)
        // Moving it by hand forgets where it was heard; unpinning, the undo.
        map.moveBeat(at: time(heard), to: time(heard + 0.001))
        #expect(map.beat(at: time(heard + 0.001))?.snapsToOnset == false)
        map.unpin(at: time(heard + 0.001))
        #expect(map.beat(at: time(heard + 0.001))?.snapsToOnset == true)
    }

    @Test func aPinPutBackOffItsOnsetDoesNotShiftTheOthers() throws {
        let (curve, truth) = clickCurve(bpm: 120, seconds: 30)
        // On its onset as heard, and one the person means 12 ms late.
        var section = rawSection(0, 30, pins: [(truth[4], 1), (truth[36] + 0.012, 1)])
        section.beats[1].snapsToOnset = false
        let (filled, _) = try BeatFitting.fillConsistent(section, curve: curve, sampleRate: rate)
        let kept = try #require(filled.beats.first { !$0.snapsToOnset })
        #expect(kept.time == time(truth[36] + 0.012))
        // Lined up by the other pin alone, the beats stay on the clicks;
        // counting the late one would move them 6 ms.
        let generated = filled.beats.filter { !$0.isPinned }
        #expect(worstError(generated, truth) < 0.001, "\(worstError(generated, truth))")
    }

    @Test func snapAgainMovesOneBeatBackOntoItsOnset() throws {
        let (curve, truth) = clickCurve(bpm: 120, seconds: 30)
        var section = rawSection(0, 30, pins: [(truth[4], 1), (truth[20] + 0.008, 1), (truth[36], 1)])
        section.beats[1].snapsToOnset = false
        let map = BeatMap(sections: [section])
        let (again, moved) = try #require(BeatFitting.snapAgain(map, at: time(truth[20] + 0.008), curve: curve, sampleRate: rate))
        #expect(abs(moved.seconds - truth[20]) < 0.001)
        let beat = try #require(again.beat(at: moved))
        #expect(beat.snapsToOnset && beat.isPinned && beat.heardTime == time(truth[20] + 0.008))
        // Only that beat moved.
        #expect(again.sections[0].beats.count == 3)
        #expect(again.beat(at: time(truth[4])) != nil && again.beat(at: time(truth[36])) != nil)
        // A beat that snaps already has nothing to snap again.
        #expect(BeatFitting.snapAgain(again, at: moved, curve: curve, sampleRate: rate) == nil)
    }

    @Test func aCopiedSectionsSnappedBeatsKeepWhereTheyWereHeard() throws {
        var section = rawSection(0, 10, pins: [(2, 1)])
        section.beats[0].heardTime = time(1.99)
        var map = BeatMap(sections: [section], usesSections: true)
        let copied = map.copySection(section.id, to: time(20), duration: time(40))
        let copy = try #require(copied)
        let beat = try #require(map.section(id: copy)?.beats.first)
        #expect(beat.time == time(22) && beat.heardTime == time(21.99))
    }

    @Test func aCancelledFillStops() async throws {
        let (curve, beats) = BeatFittingPerformanceTests.song()
        let pins = [beats[300], beats[301]].map { MappedBeat(time: time($0), position: 1, isPinned: true) }
        let section = BeatSection(kind: .consistent, start: .zero, end: time(360), steadiness: .intent, beats: pins)
        let map = BeatMap(sections: [section])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BeatFitting.fill(map, section: section.id, curve: curve, sampleRate: rate, duration: time(361))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func everyFailureSaysWhatToDo() {
        let all: [BeatFitting.Failure] = [.needsTwoAnchors, .needsBothEnds, .notAnalyzed, .unusableTempo, .tooShort]
        for failure in all {
            #expect(failure.errorDescription?.isEmpty == false)
            #expect(failure.recoverySuggestion?.isEmpty == false)
        }
        #expect(BeatFitting.Failure.unusableTempo.errorDescription! + " " + BeatFitting.Failure.unusableTempo.recoverySuggestion!
                == "Couldn't find a tempo here. Try pinning two beats farther apart.")
    }
}
