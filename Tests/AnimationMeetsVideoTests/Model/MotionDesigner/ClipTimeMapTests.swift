import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func near(_ a: CMTime, _ b: Double, within tolerance: Double = 1e-6) -> Bool {
    abs(a.seconds - b) < tolerance
}

/// Ten seconds of footage at 100%, placed at zero.
private func footage() -> TimelineClip {
    TimelineClip(source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: seconds(10))
}

/// A map of `footage()` with a point at each source second given, where it
/// plays now: linear, so the line runs straight between them, unless
/// `smooth`, as points dropped on the line are.
private func map(markers: [Double], smooth: Bool = false) -> (map: ClipTimeMap, ids: [UUID]) {
    var map = ClipTimeMap(reading: footage(), frameDuration: CMTime(value: 1, timescale: 24))
    let ids = markers.map { map.addMarker(atSource: seconds($0), time: seconds($0))! }
    if !smooth { for id in ids { map.setEase(.linear, of: id) } }
    return (map, ids)
}

/// Whether `clip` plays each of the map's points where it was put.
private func playsEveryPoint(_ map: ClipTimeMap, _ clip: TimelineClip) -> Bool {
    map.points.allSatisfy { near(clip.timelineTime(forSourceTime: $0.source), $0.time.seconds, within: 1e-5) }
}

/// `clip` played as the map writes it.
private func played(_ map: ClipTimeMap, _ clip: TimelineClip = footage()) throws -> TimelineClip {
    let written = try #require(map.writtenSpeed())
    var clip = clip
    clip.time.speed = written.speed
    clip.startOffset = written.start
    return clip
}

@Suite struct ClipTimeMapTests {
    // MARK: Points on the line

    @Test func aDroppedMarkerIsEasedInLineAndChangesNothing() throws {
        var (map, ids) = map(markers: [2, 6])
        map.setLocked(true, of: ids[0])
        map.move(ids[1], to: seconds(8))
        map.setLocked(true, of: ids[1])
        let before = try played(map)
        let added = map.addMarker(atSource: seconds(4))
        let id = try #require(added)
        let point = try #require(map.points.first { $0.id == id })
        #expect(point.smooth && point.easeIn != nil && point.easeOut != nil)
        // Its handles carry the line's speed through it: 4 s over 6 s.
        #expect(abs(map.speed(.before, at: 2) - 400.0 / 6) < 1e-6)
        #expect(abs(map.speed(.after, at: 2) - 400.0 / 6) < 1e-6)
        let after = try played(map)
        #expect(after.time.speed == before.time.speed)
        #expect(near(after.startOffset, before.startOffset.seconds))
    }

    @Test func draggingADroppedPointBendsTheLineWithoutAStep() throws {
        var (map, ids) = map(markers: [2, 8])
        map.setLocked(true, of: ids[0])
        map.setLocked(true, of: ids[1])
        let added = map.addMarker(atSource: seconds(5))
        let id = try #require(added)
        map.move(id, to: seconds(7))
        // Slower before it, faster after, the handles in line between.
        #expect(map.speed(after: 1) < 100 && map.speed(after: 2) > 100)
        #expect(abs(map.speed(.before, at: 2) - map.speed(.after, at: 2)) < 1e-6)
        let clip = try played(map)
        #expect(playsEveryPoint(map, clip))
        // The locked markers, cuts and outer stretches stay where they were.
        #expect(near(clip.startOffset, 0, within: 1e-5) && near(clip.endOffset, 10, within: 1e-5))
    }

    // MARK: Easing

    @Test func easyEaseAtALockedMarkerOnAStraightLineSlowsIntoIt() throws {
        var (map, ids) = map(markers: [2, 5, 8])
        for id in ids { map.setLocked(true, of: id) }
        #expect(map.canEase(ids[1]))
        map.setEase(.easyEase, of: ids[1])
        // As a keyframe's Easy Ease: the footage stops at the point.
        #expect(map.points[2].easeIn == .easy && map.points[2].easeOut == .easy)
        #expect(map.speed(.before, at: 2) == 0 && map.speed(.after, at: 2) == 0)
        let clip = try played(map)
        #expect(playsEveryPoint(map, clip))
        // Slow by the hit, quicker than 100% away from it to make up for it.
        #expect(clip.speed(atSource: seconds(4.99)) < 20)
        #expect(clip.speed(atSource: seconds(5.01)) < 20)
        #expect(clip.speed(atSource: seconds(2.5)) > 100)
    }

    @Test func theOutermostMarkersCanEaseWithoutMovingTheClipsEnds() throws {
        var (map, ids) = map(markers: [2, 8])
        map.move(ids[1], to: seconds(9))
        for id in ids { map.setLocked(true, of: id) }
        let straight = try played(map)
        #expect(map.canEase(ids[0]) && map.canEase(ids[1]))
        map.setEase(.easeOut, of: ids[0])
        map.setEase(.easeIn, of: ids[1])
        let eased = try played(map)
        #expect(playsEveryPoint(map, eased))
        #expect(near(eased.startOffset, straight.startOffset.seconds, within: 1e-5))
        #expect(near(eased.endOffset, straight.endOffset.seconds, within: 1e-5))
        #expect(eased.speed(atSource: seconds(2.05)) < 40)
    }

    @Test func aHandleSwingsTheOtherIntoLineUnlessMovedAlone() throws {
        var (map, ids) = map(markers: [2, 4, 7])
        map.move(ids[1], to: seconds(6))
        map.setEase(.easyEase, of: ids[1])
        // Out at a tenth of its stretch's 300%: the handle in follows, at
        // 30% too.
        map.setHandle(.after, of: ids[1], to: KeyframeEase(influence: 0.3, speed: 0.1))
        #expect(map.points[2].smooth)
        #expect(abs(map.speed(.after, at: 2) - 30) < 1e-6)
        #expect(abs(map.speed(.before, at: 2) - 30) < 1e-6)
        #expect(map.points[2].easeIn?.influence == KeyframeEase.easy.influence)
        // Alone, the handle in stays, and the speed steps at the point.
        map.setHandle(.before, of: ids[1], to: KeyframeEase(influence: 0.5, speed: 0.5), alone: true)
        #expect(!map.points[2].smooth)
        #expect(abs(map.speed(.before, at: 2) - 25) < 1e-6)
        #expect(abs(map.speed(.after, at: 2) - 30) < 1e-6)
        #expect(try playsEveryPoint(map, played(map)))
        // Put back in line, they meet at the speed they share by reach.
        map.setSmooth(true, of: ids[1])
        #expect(map.points[2].smooth)
        #expect(abs(map.speed(.before, at: 2) - map.speed(.after, at: 2)) < 1e-6)
        // Dropped on its point, a handle goes, back to the straight line.
        map.setHandle(.before, of: ids[1], to: nil)
        #expect(map.points[2].easeIn == nil && map.points[2].easePreset == .easeOut)
    }

    @Test func handlesAreHeldSoTheFootageNeverRunsBackwards() {
        var (map, ids) = map(markers: [2, 4, 7])
        map.setHandle(.after, of: ids[1], to: KeyframeEase(influence: 0.5, speed: 8), alone: true)
        // Its end stays inside the stretch: no more than the whole footage.
        #expect(map.points[2].easeOut?.speed == 2)
    }

    // MARK: Writing

    @Test func aGentleEaseWritesAFewSteps() throws {
        var (map, ids) = map(markers: [2, 8])
        for id in ids { map.setLocked(true, of: id) }
        let added = map.addMarker(atSource: seconds(5))
        map.move(try #require(added), to: seconds(5.5))
        let clip = try played(map)
        #expect(playsEveryPoint(map, clip))
        #expect(clip.time.speed.keyframes.count <= 24)
        // Each step plays its footage within a quarter frame of the line.
        for step in stride(from: 0.0, through: 10, by: 0.1) {
            let source = CMTime(seconds: step, preferredTimescale: 600)
            let line = try #require(map.time(atSource: source))
            #expect(abs(clip.timelineTime(forSourceTime: source).seconds - line.seconds) <= ClipTimeMap.stepTolerance + 1e-6)
        }
    }

    @Test func aStopTooSlowForTimeIsMadeUpBeside() throws {
        // A stop on the hit is slower than Time's 1%; the steps beside it
        // play quicker, so the hits still land.
        var (map, ids) = map(markers: [1, 2, 3])
        for id in ids { map.setLocked(true, of: id) }
        map.setEase(.easyEase, of: ids[1])
        let clip = try played(map)
        #expect(playsEveryPoint(map, clip))
        #expect(clip.time.speed.keyframes.allSatisfy { ClipTimeMap.speedRange.contains($0.value) })
    }

    // MARK: Reading

    /// Hits, a bent smooth point, an eased hit and a pace, as the designer
    /// leaves them.
    private func designed() throws -> ClipTimeMap {
        var (map, ids) = map(markers: [2, 8])
        for id in ids { map.setLocked(true, of: id) }
        let added = map.addMarker(atSource: seconds(5))
        map.move(try #require(added), to: seconds(6))
        map.setEase(.easeIn, of: ids[1])
        let paced = map.addMarker(atSource: seconds(9))
        map.setLocked(true, of: try #require(paced))
        return map
    }

    @Test func theDesignersPointsComeBackAsTheyWere() throws {
        let map = try designed()
        let written = try #require(map.writtenSpeed())
        var clip = footage()
        clip.time.speed = written.speed
        clip.startOffset = written.start
        clip.time.design = MotionDesign(map, speed: written.speed)
        // Moved along the timeline since, by the music it follows.
        clip.startOffset = CMTimeAdd(clip.startOffset, seconds(3))
        let read = ClipTimeMap(reading: clip, frameDuration: CMTime(value: 1, timescale: 24))
        #expect(read.points.map(\.locked) == map.points.map(\.locked))
        #expect(read.points.map(\.easeIn) == map.points.map(\.easeIn))
        #expect(read.points.map(\.easeOut) == map.points.map(\.easeOut))
        #expect(read.points.map(\.smooth) == map.points.map(\.smooth))
        for (a, b) in zip(read.points, map.points) { #expect(near(a.time, b.time.seconds + 3, within: 1e-5)) }
        // And they write the same again, to within the ticks they are read
        // back on.
        let again = try #require(read.writtenSpeed()).speed.keyframes
        #expect(again.count == written.speed.keyframes.count)
        for (a, b) in zip(again, written.speed.keyframes) {
            #expect(abs(a.time.seconds - b.time.seconds) < 3.0 / 240_000 && abs(a.value - b.value) < 1e-2)
        }
    }

    @Test func aSpeedChangedElsewhereIsReadFromItsKeyframes() throws {
        let map = try designed()
        let written = try #require(map.writtenSpeed())
        var clip = footage()
        clip.time.speed = written.speed
        clip.startOffset = written.start
        clip.time.design = MotionDesign(map, speed: written.speed)
        clip.time.speed = AnimatedValue(80)
        clip.time.speed.setAnimated(true, at: seconds(3))
        clip.time.speed.set(160, at: seconds(6))
        let read = ClipTimeMap(reading: clip, frameDuration: CMTime(value: 1, timescale: 24))
        #expect(!read.points.contains { $0.locked })
        #expect(!read.points.isEmpty)
    }

    @Test(arguments: [1.5, 2.5]) func movingAnInteriorMarkerKeepsTheWholeScene(_ target: Double) throws {
        var map = ClipTimeMap(trimStart: seconds(2), trimEnd: seconds(6))
        let added_a = map.addMarker(atSource: seconds(3))
        let a = try #require(added_a)
        let added_m = map.addMarker(atSource: seconds(4))
        let m = try #require(added_m)
        let added_b = map.addMarker(atSource: seconds(5))
        let b = try #require(added_b)
        for id in [a, m, b] { map.setEase(.linear, of: id) }
        map.setLocked(true, of: a)
        map.setLocked(true, of: b)
        let before = map
        map.move(m, to: seconds(target))
        #expect(map.points[2].time == seconds(target))
        #expect(abs(map.speed(after: 1) - 100 / (target - 1)) < 1e-6)
        #expect(abs(map.speed(after: 2) - 100 / (3 - target)) < 1e-6)
        #expect(map.stretches.first == before.stretches.first)
        #expect(map.stretches.last == before.stretches.last)
        #expect(map.trimStart == seconds(2) && map.trimEnd == seconds(6))
        #expect(map.span?.start == .zero && map.span?.end == seconds(4))
        var unlocked = before
        unlocked.setLocked(false, of: a)
        unlocked.setLocked(false, of: b)
        unlocked.move(m, to: seconds(target))
        #expect(unlocked.points[2].time == map.points[2].time)
        let written = try #require(map.writtenSpeed())
        var clip = TimelineClip(source: .adjustment, startOffset: written.start, trimStart: map.trimStart, trimEnd: map.trimEnd)
        clip.time.speed = written.speed
        #expect(playsEveryPoint(map, clip))
    }

    @Test func lockedMarkersKeepTheirFrameAndTimeButCanEase() throws {
        var (map, ids) = map(markers: [2, 4, 6])
        let id = ids[1]
        map.setLocked(true, of: id)
        let before = map
        map.move(id, to: seconds(5))
        map.remove(id)
        #expect(map == before)
        map.setHandle(.after, of: id, to: .easy)
        #expect(map.points[2].easeOut == .easy)
        map.setLocked(false, of: id)
        map.move(id, to: seconds(5))
        #expect(map.points[2].time == seconds(5))
    }

    @Test func edgeMarkersRetimeAndOnlyEaseInsideTheClip() throws {
        var map = ClipTimeMap(trimStart: seconds(2), trimEnd: seconds(6))
        let last = try #require(map.points.last?.id)
        let first = map.points[0].id
        map.move(last, to: seconds(5))
        #expect(map.trimEnd == seconds(6))
        #expect(map.span?.end == seconds(5))
        #expect(map.speed(after: 0) == 80)
        map.remove(first)
        map.remove(last)
        #expect(map.points.count == 2)
        map.setEase(.easyEase, of: first)
        map.setEase(.easyEase, of: last)
        #expect(map.points[0].easeIn == nil && map.points[0].easeOut == .easy)
        #expect(map.points[1].easeIn == .easy && map.points[1].easeOut == nil)
        let startAdded = map.addMarker(atSource: map.trimStart)
        #expect(startAdded == nil)
        let endAdded = map.addMarker(atSource: map.trimEnd)
        #expect(endAdded == nil)
    }

    @Test func readingSpeedKeysCreatesOnlyInteriorUnlockedMarkers() {
        var clip = footage()
        clip.time.speed = AnimatedValue(50, keyframes: [
            Keyframe(time: .zero, value: 50, hold: true),
            Keyframe(time: seconds(4), value: 50),
            Keyframe(time: CMTime(value: 97, timescale: 24), value: 200),
            Keyframe(time: seconds(10), value: 200),
        ])
        let map = ClipTimeMap(reading: clip, frameDuration: CMTime(value: 1, timescale: 24))
        #expect(map.points.count == 3)
        #expect(map.points[1].source == CMTime(value: 97, timescale: 24))
        #expect(map.points.allSatisfy { !$0.locked && !$0.eased })
    }

    @Test func aSavedLockedEdgeBecomesInteriorAfterAnOutwardTrim() {
        var clip = footage()
        clip.trimStart = seconds(2)
        var map = ClipTimeMap(reading: clip, frameDuration: CMTime(value: 1, timescale: 24))
        map.setLocked(true, of: map.points[0].id)
        clip.time.design = MotionDesign(map, speed: clip.time.speed)
        clip.trimStart = .zero
        let read = ClipTimeMap(reading: clip, frameDuration: CMTime(value: 1, timescale: 24))
        #expect(!read.points[0].locked)
        #expect(read.points[1].source == seconds(2) && read.points[1].locked)
    }
    @Test func movingAMarkerKeepsTheOuterStretchesAndSmoothNeighbours() throws {
        var (map, ids) = map(markers: [2, 4, 6], smooth: true)
        for id in [ids[0], ids[2]] {
            map.setEase(.easyEase, of: id)
            map.setHandle(.after, of: id, to: KeyframeEase(influence: 0.3, speed: 0.5))
        }
        let first = map.stretches.first
        let last = map.stretches.last
        map.move(ids[1], to: seconds(5))
        #expect(map.stretches.first == first && map.stretches.last == last)
        for index in [1, 3] {
            #expect(abs(map.speed(.before, at: index) - map.speed(.after, at: index)) < 1e-6)
        }
    }

    @Test(arguments: [-20.0, 20.0]) func draggingStopsAtTheSpeedLimits(_ target: Double) {
        var (map, ids) = map(markers: [3, 4, 5])
        map.move(ids[1], to: seconds(target))
        #expect(map.isPlayable)
        #expect(map.points[2].time > map.points[1].time)
        #expect(map.points[2].time < map.points[3].time)
        #expect(map.stretches.allSatisfy { $0.speed <= 10_000 + 1e-8 && $0.speed >= 1 - 1e-10 })
    }
}
