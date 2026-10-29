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
    // MARK: Solving

    @Test func draggingAMarkerFromAHitRetimesBothSides() throws {
        var (map, ids) = map(markers: [2, 4])
        map.setKind(.hit, of: ids[0])
        map.move(ids[1], to: seconds(6))
        // 2 s of footage over 4 s is 50%, and so is everything either side.
        #expect(abs(map.speed(after: 0) - 50) < 1e-9)
        #expect(abs(map.speedBeforeFirst - 50) < 1e-9)
        #expect(abs(map.speedAfterLast - 50) < 1e-9)
        let span = try #require(map.span)
        #expect(near(span.start, -2) && near(span.end, 18))

        let clip = try played(map)
        #expect(!clip.time.speed.isAnimated && clip.time.speed.value == 50)
        #expect(near(clip.timelineTime(forSourceTime: seconds(2)), 2))
        #expect(near(clip.timelineTime(forSourceTime: seconds(4)), 6))
    }

    @Test func aPaceMarkerSetsTheSpeedAfterIt() throws {
        var (map, ids) = map(markers: [2, 4])
        map.setKind(.hit, of: ids[0])
        map.move(ids[1], to: seconds(6))
        // A marker put on a later frame lands where it plays now, at 50%
        // too: 2 s of footage past the second takes 4 s.
        let added6 = map.addMarker(atSource: seconds(6))
        let pace = try #require(added6)
        #expect(near(map.points[2].time, 10))
        #expect(map.setKind(.pace(200), of: pace) == nil)
        #expect(abs(map.speedAfterLast - 200) < 1e-9)

        let clip = try played(map)
        #expect(clip.time.speed.keyframes.count == 2)
        #expect(clip.time.speed.keyframes[0].hold && clip.time.speed.keyframes[0].value == 50)
        #expect(clip.time.speed.keyframes[1].value == 200)
        #expect(near(clip.timelineTime(forSourceTime: seconds(6)), 10, within: 1e-5))
        // 4 s more footage at 200% take 2 s.
        #expect(near(clip.endOffset, 12, within: 1e-5))
    }

    @Test func aPaceMarkerMovesTheMarkerAfterIt() {
        var (map, ids) = map(markers: [0, 4, 8])
        map.move(ids[2], to: seconds(20))
        #expect(map.setKind(.pace(50), of: ids[0]) == nil)
        #expect(near(map.points[1].time, 8))
        // The stretch after it takes up the difference.
        #expect(abs(map.speed(after: 1) - 4.0 / 12 * 100) < 1e-6)
        #expect(near(map.points[2].time, 20))
    }

    @Test func aPaceMarkerBeforeAHitAsksFirst() {
        var (map, ids) = map(markers: [0, 4])
        map.setKind(.hit, of: ids[1])
        #expect(map.setKind(.pace(50), of: ids[0]) == .hitWouldMove(ids[1]))
        #expect(map.points[0].kind == .marker)
        #expect(map.setKind(.pace(50), of: ids[0], confirmed: true) == nil)
        #expect(map.points[1].kind == .marker)
        #expect(near(map.points[1].time, 8))
    }

    @Test func aHitAfterAPaceMarkerAsksFirst() {
        var (map, ids) = map(markers: [0, 4])
        map.setKind(.pace(50), of: ids[0])
        #expect(map.setKind(.hit, of: ids[1]) == .paceWouldEnd(ids[0]))
        #expect(map.setKind(.hit, of: ids[1], confirmed: true) == nil)
        #expect(map.points[0].kind == .marker && map.points[1].kind == .hit)
    }

    @Test func movingThePointAfterAPaceMarkerSetsThePace() {
        var (map, ids) = map(markers: [0, 4])
        map.setKind(.pace(100), of: ids[0])
        map.move(ids[1], to: seconds(8))
        #expect(map.points[0].kind == .pace(50))
        #expect(near(map.points[1].time, 8))
    }

    @Test func aPointStopsWhereTheClipCantPlayFasterOrBackwards() {
        var (map, ids) = map(markers: [2, 4, 6])
        map.setKind(.hit, of: ids[0])
        map.setKind(.hit, of: ids[2])
        map.move(ids[1], to: seconds(9))
        #expect(map.isPlayable)
        #expect(map.points[1].time < map.points[2].time)
        #expect(map.speed(after: 1) <= ClipTimeMap.speedRange.upperBound)
        #expect(near(map.points[2].time, 6))
    }

    @Test func removingAPointBetweenAPaceAndAHitEndsThePace() {
        var (map, ids) = map(markers: [0, 2, 6])
        map.setKind(.hit, of: ids[2])
        map.setKind(.pace(100), of: ids[0])
        map.remove(ids[1])
        #expect(map.points.map(\.kind) == [.marker, .hit])
    }

    // MARK: Points on the line

    @Test func aDroppedMarkerIsEasedInLineAndChangesNothing() throws {
        var (map, ids) = map(markers: [2, 6])
        map.setKind(.hit, of: ids[0])
        map.setKind(.hit, of: ids[1])
        map.move(ids[1], to: seconds(8))
        let before = try played(map)
        let added = map.addMarker(atSource: seconds(4))
        let id = try #require(added)
        let point = try #require(map.points.first { $0.id == id })
        #expect(point.smooth && point.easeIn != nil && point.easeOut != nil)
        // Its handles carry the line's speed through it: 4 s over 6 s.
        #expect(abs(map.speed(.before, at: 1) - 400.0 / 6) < 1e-6)
        #expect(abs(map.speed(.after, at: 1) - 400.0 / 6) < 1e-6)
        let after = try played(map)
        #expect(after.time.speed == before.time.speed)
        #expect(near(after.startOffset, before.startOffset.seconds))
    }

    @Test func draggingADroppedPointBendsTheLineWithoutAStep() throws {
        var (map, ids) = map(markers: [2, 8])
        map.setKind(.hit, of: ids[0])
        map.setKind(.hit, of: ids[1])
        let added = map.addMarker(atSource: seconds(5))
        let id = try #require(added)
        map.move(id, to: seconds(7))
        // Slower before it, faster after, the handles in line between.
        #expect(map.speed(after: 0) < 100 && map.speed(after: 1) > 100)
        #expect(abs(map.speed(.before, at: 1) - map.speed(.after, at: 1)) < 1e-6)
        let clip = try played(map)
        #expect(playsEveryPoint(map, clip))
        // The hits stay on their beats. The open ends carry on at the
        // straight speeds beside them: 3 s of footage over 5 s before, and
        // 3 s over 1 s after.
        #expect(near(clip.startOffset, 2 - 2 / 0.6, within: 1e-5) && near(clip.endOffset, 8 + 2.0 / 3, within: 1e-5))
    }

    // MARK: Easing

    @Test func easyEaseAtAHitOnAStraightLineSlowsIntoIt() throws {
        var (map, ids) = map(markers: [2, 5, 8])
        for id in ids { map.setKind(.hit, of: id) }
        #expect(map.canEase(ids[1]))
        map.setEase(.easyEase, of: ids[1])
        // As a keyframe's Easy Ease: the footage stops at the point.
        #expect(map.points[1].easeIn == .easy && map.points[1].easeOut == .easy)
        #expect(map.speed(.before, at: 1) == 0 && map.speed(.after, at: 1) == 0)
        let clip = try played(map)
        #expect(playsEveryPoint(map, clip))
        // Slow by the hit, quicker than 100% away from it to make up for it.
        #expect(clip.speed(atSource: seconds(4.99)) < 20)
        #expect(clip.speed(atSource: seconds(5.01)) < 20)
        #expect(clip.speed(atSource: seconds(2.5)) > 100)
    }

    @Test func theOutermostHitsCanEaseWithoutMovingTheClipsEnds() throws {
        var (map, ids) = map(markers: [2, 8])
        for id in ids { map.setKind(.hit, of: id) }
        map.move(ids[1], to: seconds(11))
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
        #expect(map.points[1].smooth)
        #expect(abs(map.speed(.after, at: 1) - 30) < 1e-6)
        #expect(abs(map.speed(.before, at: 1) - 30) < 1e-6)
        #expect(map.points[1].easeIn?.influence == KeyframeEase.easy.influence)
        // Alone, the handle in stays, and the speed steps at the point.
        map.setHandle(.before, of: ids[1], to: KeyframeEase(influence: 0.5, speed: 0.5), alone: true)
        #expect(!map.points[1].smooth)
        #expect(abs(map.speed(.before, at: 1) - 25) < 1e-6)
        #expect(abs(map.speed(.after, at: 1) - 30) < 1e-6)
        #expect(try playsEveryPoint(map, played(map)))
        // Put back in line, they meet at the speed they share by reach.
        map.setSmooth(true, of: ids[1])
        #expect(map.points[1].smooth)
        #expect(abs(map.speed(.before, at: 1) - map.speed(.after, at: 1)) < 1e-6)
        // Dropped on its point, a handle goes, back to the straight line.
        map.setHandle(.before, of: ids[1], to: nil)
        #expect(map.points[1].easeIn == nil && map.points[1].easePreset == .easeOut)
    }

    @Test func handlesAreHeldSoTheFootageNeverRunsBackwards() {
        var (map, ids) = map(markers: [2, 4, 7])
        map.setHandle(.after, of: ids[1], to: KeyframeEase(influence: 0.5, speed: 8), alone: true)
        // Its end stays inside the stretch: no more than the whole footage.
        #expect(map.points[1].easeOut?.speed == 2)
    }

    @Test func aPaceHoldsItsStretchStraight() {
        var (map, ids) = map(markers: [2, 4, 7], smooth: true)
        map.setEase(.easyEase, of: ids[1])
        #expect(map.points[1].easeOut != nil && map.points[2].easeIn != nil)
        map.setKind(.pace(200), of: ids[1])
        // Its handle out and the next point's handle in go.
        #expect(map.points[1].easeIn != nil && map.points[1].easeOut == nil)
        #expect(map.points[2].easeIn == nil)
        #expect(!map.canEase(.after, of: 1) && !map.canEase(.before, of: 2))
        map.setEase(.easyEase, of: ids[1])
        #expect(map.points[1].easePreset == .easeIn)
        #expect(abs(map.speed(after: 1) - 200) < 1e-9)
    }

    @Test func aPointThatCantEaseEitherSide() {
        // A pace marker on the clip's first frame: no footage before it, and
        // its pace holds the stretch after it.
        var (map, ids) = map(markers: [0, 4])
        map.setKind(.pace(50), of: ids[0])
        #expect(!map.canEase(ids[0]))
        map.setEase(.easyEase, of: ids[0])
        #expect(!map.points[0].eased)
    }

    // MARK: Edge keyframes

    @Test func aClipWithNoPointsHasEdgeKeyframesWithoutHandles() throws {
        let map = ClipTimeMap(reading: footage(), frameDuration: CMTime(value: 1, timescale: 24))
        #expect(map.points.isEmpty)
        #expect(map.hasEdgeKeyframe(.start) && map.hasEdgeKeyframe(.end))
        #expect(map.edgeEase(.start) == nil && map.edgeEase(.end) == nil)
        // Nothing to write until a handle is pulled out.
        #expect(map.writtenSpeed() == nil)
        let stretch = try #require(map.edgeStretch(.start))
        #expect(stretch.start == (0, 0) && stretch.end == (10, 10))
    }

    @Test func anEdgeHandleOnlyReachesIntoTheClip() throws {
        var (map, _) = map(markers: [4, 6])
        map.setEdgeHandle(.start, to: .easy)
        map.setEdgeHandle(.end, to: .easy)
        let start = try #require(map.edgeStretch(.start))
        let end = try #require(map.edgeStretch(.end))
        // The first frame eases out into the clip, the last in to it: the
        // open ends are the only stretches either handle reaches.
        #expect(start.leaving == .easy && start.arriving == nil && start.start.source == 0)
        #expect(end.arriving == .easy && end.leaving == nil && end.end.source == 10)
        #expect(map.speed(at: .start) == 0 && map.speed(at: .end) == 0)
        // Easing an edge never moves it.
        let span = try #require(map.span)
        #expect(near(span.start, 0, within: 1e-4) && near(span.end, 10, within: 1e-4), "\(span.start.seconds) \(span.end.seconds)")
        let clip = try played(map)
        #expect(playsEveryPoint(map, clip))
        #expect(near(clip.timelineTime(forSourceTime: seconds(10)), 10, within: 1e-4))
    }

    @Test func aPointOnTheClipsFirstFrameStandsInForItsEdgeKeyframe() {
        var (map, ids) = map(markers: [0, 5])
        #expect(!map.hasEdgeKeyframe(.start) && map.hasEdgeKeyframe(.end))
        map.setEdgeHandle(.start, to: .easy)
        #expect(map.edgeEase(.start) == nil)
        // Nor does that point have a handle before the clip.
        map.setHandle(.before, of: ids[0], to: .easy, alone: true)
        #expect(map.points[0].easeIn == nil)
    }

    @Test func aLastPaceMarkerHoldsTheLastFrameStraight() throws {
        var (map, ids) = map(markers: [4, 6])
        map.setEdgeHandle(.end, to: .easy)
        map.setKind(.pace(150), of: ids[1])
        // Still shown, but its handle can't bend the pace's stretch.
        #expect(map.hasEdgeKeyframe(.end) && !map.canEase(.end))
        #expect(map.edgeEase(.end) == nil && map.stretches.last?.arriving == nil)
        map.setEdgeHandle(.end, to: .easy)
        #expect(map.edgeEase(.end) == nil)
    }

    @Test func aClipWithNoPointsWritesItsEdgeHandles() throws {
        var map = ClipTimeMap(reading: footage(), frameDuration: CMTime(value: 1, timescale: 24))
        map.setEdgeHandle(.start, to: .easy)
        let clip = try played(map)
        #expect(clip.time.speed.isAnimated)
        #expect(near(clip.startOffset, 0) && near(clip.timelineTime(forSourceTime: seconds(10)), 10, within: 1e-4))
        // And it comes back on the clip's edge.
        var saved = clip
        saved.time.design = MotionDesign(map, speed: clip.time.speed)
        let read = ClipTimeMap(reading: saved, frameDuration: CMTime(value: 1, timescale: 24))
        #expect(read.points.isEmpty && read.edgeEase(.start) == .easy && read.edgeEase(.end) == nil)
    }

    // MARK: Writing

    @Test func aGentleEaseWritesAFewSteps() throws {
        var (map, ids) = map(markers: [2, 8])
        for id in ids { map.setKind(.hit, of: id) }
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
        for id in ids { map.setKind(.hit, of: id) }
        map.setEase(.easyEase, of: ids[1])
        let clip = try played(map)
        #expect(playsEveryPoint(map, clip))
        #expect(clip.time.speed.keyframes.allSatisfy { ClipTimeMap.speedRange.contains($0.value) })
    }

    // MARK: Reading

    @Test func aKeyframeAfterAHoldIsAPaceMarker() {
        var clip = footage()
        clip.time.speed = AnimatedValue(50, keyframes: [
            Keyframe(time: seconds(2), value: 50, hold: true),
            Keyframe(time: seconds(6), value: 200),
        ])
        let map = ClipTimeMap(reading: clip, frameDuration: CMTime(value: 1, timescale: 24))
        #expect(map.points.map(\.kind) == [.marker, .pace(200)])
        #expect(map.points.map(\.source) == [seconds(2), seconds(6)])
        // From the clip's start at zero, 6 s of footage at 50%.
        #expect(near(map.points[1].time, 12, within: 1e-5))
    }

    @Test func twoKeyframesAFrameApartAreOnePaceMarker() {
        var clip = footage()
        clip.time.speed = AnimatedValue(50, keyframes: [
            Keyframe(time: seconds(1), value: 50),
            Keyframe(time: seconds(4), value: 50),
            Keyframe(time: CMTime(value: 97, timescale: 24), value: 200),
        ])
        let map = ClipTimeMap(reading: clip, frameDuration: CMTime(value: 1, timescale: 24))
        #expect(map.points.map(\.kind) == [.marker, .pace(200)])
        #expect(map.points[1].source == CMTime(value: 97, timescale: 24))
    }

    @Test func aClipAtOneSpeedHasNoPoints() {
        var clip = footage()
        clip.time.speed = AnimatedValue(80)
        let map = ClipTimeMap(reading: clip, frameDuration: CMTime(value: 1, timescale: 24))
        #expect(map.points.isEmpty && map.restingSpeed == 80)
        #expect(map.writtenSpeed() == nil)
    }

    /// Hits, a bent smooth point, an eased hit and a pace, as the designer
    /// leaves them.
    private func designed() throws -> ClipTimeMap {
        var (map, ids) = map(markers: [2, 8])
        for id in ids { map.setKind(.hit, of: id) }
        let added = map.addMarker(atSource: seconds(5))
        map.move(try #require(added), to: seconds(6))
        map.setEase(.easeIn, of: ids[1])
        let paced = map.addMarker(atSource: seconds(9))
        map.setKind(.pace(150), of: try #require(paced))
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
        #expect(read.points.map(\.kind) == map.points.map(\.kind))
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
        #expect(!read.points.contains { $0.isHit })
        #expect(!read.points.isEmpty)
    }

    @Test func paceMarkersReadFromKeyframesWriteTheSameAgain() throws {
        var (map, ids) = map(markers: [2, 4])
        map.setKind(.hit, of: ids[0])
        map.move(ids[1], to: seconds(6))
        let added6 = map.addMarker(atSource: seconds(6))
        map.setKind(.pace(200), of: try #require(added6))
        // The point after a pace marker follows it; the one after that
        // moves freely: 1 s of footage over 4 s.
        let added8 = map.addMarker(atSource: seconds(8))
        let added9 = map.addMarker(atSource: seconds(9))
        #expect(added8 != nil)
        map.setEase(.linear, of: try #require(added8))
        map.setEase(.linear, of: try #require(added9))
        map.move(try #require(added9), to: seconds(15))
        #expect(near(map.points[3].time, 11))

        let clip = try played(map)
        let read = ClipTimeMap(reading: clip, frameDuration: CMTime(value: 1, timescale: 24))
        // Without the designer's points, the steps come back as pace
        // markers, and the speed before them as the clip's own.
        #expect(read.points.map(\.source) == [seconds(6), seconds(8)])
        #expect(read.points.map(\.kind) == [.pace(200), .pace(25)])
        #expect(read.restingSpeed == 50)
        let again = try played(read, footage())
        #expect(again.time.speed.keyframes.map(\.time) == clip.time.speed.keyframes.map(\.time))
        #expect(again.time.speed.keyframes.map(\.hold) == clip.time.speed.keyframes.map(\.hold))
        for (a, b) in zip(again.time.speed.keyframes, clip.time.speed.keyframes) { #expect(abs(a.value - b.value) < 1e-4) }
        #expect(near(again.startOffset, clip.startOffset.seconds, within: 1e-5))
    }
}
