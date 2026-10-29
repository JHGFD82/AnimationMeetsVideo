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
/// plays now.
private func map(markers: [Double]) -> (map: ClipTimeMap, ids: [UUID]) {
    var map = ClipTimeMap(reading: footage(), frameDuration: CMTime(value: 1, timescale: 24))
    let ids = markers.map { map.addMarker(atSource: seconds($0), time: seconds($0))! }
    return (map, ids)
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

    // MARK: Writing

    @Test func easedCornersStillPlayEveryPointWhereItWasPut() throws {
        var (map, ids) = map(markers: [1, 3])
        map.setKind(.hit, of: ids[0])
        map.move(ids[1], to: seconds(5))
        let added5 = map.addMarker(atSource: seconds(5))
        let third = try #require(added5)
        map.move(third, to: seconds(6))
        map.setKind(.hit, of: third)
        let added8 = map.addMarker(atSource: seconds(8))
        let fourth = try #require(added8)
        map.move(fourth, to: seconds(7))
        for point in map.points { map.setEase(.easyEase, of: point.id) }
        let clip = try played(map)
        #expect(clip.time.speed.isAnimated)
        for point in map.points {
            #expect(near(clip.timelineTime(forSourceTime: point.source), point.time.seconds, within: 1e-5))
        }
        // The speed doesn't step anywhere.
        #expect(!clip.time.speed.keyframes.contains { $0.hold })
    }

    @Test func rampsShareTheirStretch() {
        var (map, ids) = map(markers: [2, 4])
        map.setEase(TimeEase(before: 0.2, after: 0.8), of: ids[0])
        // The stretch from 2 s to 4 s has 10% left for the second's ramp in.
        map.setEase(TimeEase(before: 0.5, after: 0.4), of: ids[1])
        #expect(abs((map.points[1].ease?.before ?? 0) - 0.1) < 1e-9)
        #expect(map.points[1].ease?.after == 0.4)
        // Reach is held to its range.
        map.setEase(TimeEase(before: 2, after: -1), of: ids[0])
        #expect(map.points[0].ease == TimeEase(before: TimeEase.reach.upperBound, after: TimeEase.reach.lowerBound))
    }

    @Test func longerRampsStillPlayEveryPointWhereItWasPut() throws {
        var (map, ids) = map(markers: [1, 3])
        map.setKind(.hit, of: ids[0])
        map.move(ids[1], to: seconds(5))
        let added = map.addMarker(atSource: seconds(6))
        let third = try #require(added)
        map.move(third, to: seconds(6))
        map.setEase(TimeEase(before: 0.15, after: 0.7), of: ids[1])
        let clip = try played(map)
        for point in map.points {
            #expect(near(clip.timelineTime(forSourceTime: point.source), point.time.seconds, within: 1e-5))
        }
        // The ramps end where their reach says: 15% of the 2 s before and
        // 70% of the 3 s after.
        let times = clip.time.speed.keyframes.map(\.time.seconds)
        #expect(times.contains { abs($0 - 2.7) < 1e-4 })
        #expect(times.contains { abs($0 - 5.1) < 1e-4 })
    }

    @Test func rampsThatWouldCrossAreShrunkToShareTheStretch() throws {
        var (map, ids) = map(markers: [2, 4])
        map.move(ids[1], to: seconds(6))
        map.setEase(TimeEase(before: 0.5, after: 0.8), of: ids[0])
        map.setEase(TimeEase(before: 0.1, after: 0.5), of: ids[1])
        // A third point between them halves the stretch, but each keeps its
        // share; writing makes room rather than crossing them.
        let added = map.addMarker(atSource: seconds(3))
        let middle = try #require(added)
        map.setEase(TimeEase(before: 0.9, after: 0.9), of: middle)
        map.move(middle, to: seconds(3))
        let clip = try played(map)
        let times = clip.time.speed.keyframes.map(\.time)
        #expect(times == times.sorted())
        for point in map.points {
            #expect(near(clip.timelineTime(forSourceTime: point.source), point.time.seconds, within: 1e-5))
        }
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

    @Test func whatIsWrittenReadsBackAsTheSamePoints() throws {
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
        map.move(try #require(added9), to: seconds(15))
        #expect(near(map.points[3].time, 11))

        let clip = try played(map)
        let read = ClipTimeMap(reading: clip, frameDuration: CMTime(value: 1, timescale: 24))
        // Hits are the designer's, and points where nothing changes leave
        // no keyframe: the steps come back as pace markers.
        #expect(read.points.map(\.source) == [seconds(2), seconds(6), seconds(8)])
        #expect(read.points.map(\.kind) == [.marker, .pace(200), .pace(25)])
        // And write the same again.
        let again = try played(read, footage())
        #expect(again.time.speed.keyframes.map(\.time) == clip.time.speed.keyframes.map(\.time))
        #expect(again.time.speed.keyframes.map(\.hold) == clip.time.speed.keyframes.map(\.hold))
        for (a, b) in zip(again.time.speed.keyframes, clip.time.speed.keyframes) { #expect(abs(a.value - b.value) < 1e-4) }
        #expect(near(again.startOffset, clip.startOffset.seconds, within: 1e-5))
    }

    @Test func easedCornersReadBackWithoutTheirRampKeyframes() throws {
        var (map, ids) = map(markers: [2, 4, 7])
        map.move(ids[1], to: seconds(6))
        map.setEase(.easyEase, of: ids[1])
        let clip = try played(map)
        #expect(clip.time.speed.keyframes.count > 3)
        let read = ClipTimeMap(reading: clip, frameDuration: CMTime(value: 1, timescale: 24))
        #expect(read.points.map(\.source).contains(seconds(4)))
        #expect(read.points.first { $0.source == seconds(4) }?.eased == true)
        // Shaped ramps read back as they were shaped, so they write the same
        // again. The marker at 7 s changes no speed, but beside an eased
        // point it keeps its keyframe, so the ramp out is read against the
        // same stretch.
        var shaped = map
        shaped.setEase(TimeEase(before: 0.6, after: 0.2), of: ids[1])
        let written = try played(shaped)
        let reread = ClipTimeMap(reading: written, frameDuration: CMTime(value: 1, timescale: 24))
        let ease = try #require(reread.points.first { $0.source == seconds(4) }?.ease)
        #expect(abs((ease.before ?? 0) - 0.6) < 1e-4 && abs((ease.after ?? 0) - 0.2) < 1e-4)
        let again = try played(reread)
        #expect(again.time.speed.keyframes.count == written.time.speed.keyframes.count)
        for (a, b) in zip(again.time.speed.keyframes, written.time.speed.keyframes) {
            #expect(abs(a.time.seconds - b.time.seconds) < 2.0 / 240_000)
        }
        #expect(read.points.allSatisfy { [seconds(2), seconds(4), seconds(7)].contains($0.source) })
    }

    /// A corner from 50% to 300%: 2 s of footage over 4 s, then 3 s over 1 s.
    private func corner() -> (map: ClipTimeMap, ids: [UUID]) {
        var (map, ids) = map(markers: [2, 4, 7])
        map.move(ids[1], to: seconds(6))
        return (map, ids)
    }

    @Test func easeInAndEaseOutRampOnlyOnTheirSide() throws {
        for (preset, speed) in [(KeyframeEase.Preset.easeIn, 300.0), (.easeOut, 50.0)] {
            var (map, ids) = corner()
            map.setEase(preset, of: ids[1])
            #expect(map.points[1].easePreset == preset)
            let clip = try played(map)
            // Ease In arrives at the speed after the point; Ease Out leaves
            // at the speed before it. The keyframe eases the same side.
            let keyframe = try #require(clip.time.speed.keyframes.first { $0.time == map.points[1].source })
            #expect(abs(keyframe.value - speed) < 1e-6)
            #expect((keyframe.easeIn != nil) == (preset == .easeIn))
            #expect((keyframe.easeOut != nil) == (preset == .easeOut))
            #expect(!clip.time.speed.keyframes.contains { $0.hold })
            for point in map.points {
                #expect(near(clip.timelineTime(forSourceTime: point.source), point.time.seconds, within: 1e-5))
            }
            // And it reads back as the same ease.
            let read = ClipTimeMap(reading: clip, frameDuration: CMTime(value: 1, timescale: 24))
            #expect(read.points.first { $0.source == seconds(4) }?.easePreset == preset)
        }
    }

    @Test func easyEaseSharesTheChangeOfSpeedBetweenItsRamps() throws {
        var (map, ids) = corner()
        map.setEase(.easyEase, of: ids[1])
        let clip = try played(map)
        // A third of 2 s before and of 3 s after: the 250% change is split
        // 2:3, so the point passes through 150%.
        let keyframe = try #require(clip.time.speed.keyframes.first { $0.time == map.points[1].source })
        #expect(abs(keyframe.value - 150) < 1e-6)
        // Linear takes the ease away, and the corner steps again.
        map.setEase(.linear, of: ids[1])
        #expect(map.points[1].ease == nil)
        #expect(try played(map).time.speed.keyframes.contains { $0.hold })
    }

    @Test func onlyAPointWhereTheSpeedChangesCanEase() {
        let (three, ids) = corner()
        #expect(three.canEase(ids[1]))
        // The open ends carry on at the speed beside the outermost points.
        #expect(!three.canEase(ids[0]))
        #expect(!three.canEase(ids[2]))
        // Two points: both outermost, so the speed is the same throughout.
        var (two, pair) = map(markers: [2, 4])
        two.move(pair[1], to: seconds(6))
        #expect(!pair.contains { two.canEase($0) })
    }
}
