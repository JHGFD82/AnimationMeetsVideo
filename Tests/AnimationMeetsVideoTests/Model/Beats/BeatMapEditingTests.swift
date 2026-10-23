import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func s(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 48_000) }
private let song = s(100)
private let snap = s(0.5)

@Suite struct BeatMapEditingTests {
    private func ranges(_ map: BeatMap) -> [[Double]] {
        map.sections.map { [$0.start.seconds, $0.end.seconds] }
    }

    @Test func drawnSectionsStopAtTheirNeighboursAndClickIn() {
        var map = BeatMap()
        map.drawSection(.consistent, from: s(10), to: s(30), duration: song, snap: snap)
        // Drawn leftward from just past the first, ending near the start of the song.
        map.drawSection(.ramp, from: s(40), to: s(30.3), duration: song, snap: snap)
        map.drawSection(.none, from: s(0.4), to: s(8), duration: song, snap: snap)
        // Overlapping the first section: stops at its edge.
        map.drawSection(.consistent, from: s(60), to: s(35), duration: song, snap: snap)
        #expect(ranges(map) == [[0, 8], [10, 30], [30, 40], [40, 60]])
        // Starting inside a section draws nothing.
        #expect(map.drawSection(.ramp, from: s(20), to: s(70), duration: song, snap: snap) == nil)
    }

    @Test func aDrawnStartSnappedOntoTheNextSectionStillDrawsInItsGap() {
        var map = BeatMap()
        map.drawSection(.consistent, from: s(20), to: s(30), duration: song, snap: .zero)
        // The drag started at 19.8, in the gap, and its start snapped to 20.
        #expect(map.drawSection(.ramp, from: s(20), to: s(12), duration: song, snap: .zero) == nil)
        map.drawSection(.ramp, from: s(20), to: s(12), in: s(19.8), duration: song, snap: .zero)
        #expect(ranges(map) == [[12, 20], [20, 30]])
    }

    @Test func markingUpToATimeFillsBackToTheSectionBefore() {
        var map = BeatMap()
        // Pressed at each change as the song plays.
        map.drawSection(.consistent, upTo: s(20), duration: song)
        map.drawSection(.ramp, upTo: s(30), duration: song)
        map.drawSection(.none, from: s(60), to: s(70), duration: song, snap: .zero)
        // Stops at its own gap's start, not at earlier unmarked song.
        map.drawSection(.consistent, upTo: s(50), duration: song)
        #expect(ranges(map) == [[0, 20], [20, 30], [30, 50], [60, 70]])
        // Inside a section, or right after the one before, there is nothing to mark.
        #expect(map.drawSection(.ramp, upTo: s(65), duration: song) == nil)
        #expect(map.drawSection(.ramp, upTo: s(70.05), duration: song) == nil)
    }

    @Test func pastingStartsTheSectionOnAPinnedDownbeatAndSkipsRamps() throws {
        var map = BeatMap(sections: [
            BeatSection(kind: .consistent, start: s(10), end: s(20), isConfirmed: true, beats: [MappedBeat(time: s(12))]),
            BeatSection(kind: .ramp, start: s(20), end: s(30)),
        ])
        let details = BeatSectionDetails(tempo: 100, beatsPerMeasure: 6, isMeasureSet: true, steadiness: .intent)
        let intoConsistent = map.paste(details, into: map.sections[0].id)
        #expect(intoConsistent)
        let pasted = map.sections[0]
        #expect(pasted.beats == [MappedBeat(time: s(10), position: 1, isPinned: true)])
        #expect(pasted.beatsPerMeasure == 6)
        #expect(pasted.isMeasureSet)
        #expect(pasted.steadiness == .intent)
        #expect(!pasted.isConfirmed)
        let intoRamp = map.paste(details, into: map.sections[1].id)
        #expect(!intoRamp)
    }

    @Test func doubleClickFillsTheGapOrChangesTheKind() throws {
        var map = BeatMap()
        map.drawSection(.consistent, from: s(10), to: s(30), duration: song, snap: snap)
        map.drawSection(.consistent, from: s(50), to: s(70), duration: song, snap: snap)
        let filledID = map.fill(at: s(40), with: .ramp, duration: song)
        let filled = try #require(filledID)
        #expect(map.section(id: filled)?.range == CMTimeRange(start: s(30), end: s(50)))
        map.fill(at: s(80), with: .none, duration: song)
        #expect(ranges(map).last == [70, 100])
        map.fill(at: s(20), with: .ramp, duration: song)
        #expect(map.sections[0].kind == .ramp)
    }

    @Test func edgesStopAtNeighboursAndClickInNearThem() {
        var map = BeatMap()
        let first = map.drawSection(.consistent, from: s(10), to: s(30), duration: song, snap: snap)!
        map.drawSection(.consistent, from: s(40), to: s(60), duration: song, snap: snap)
        map.moveEdge(.end, of: first, to: s(45), duration: song, snap: snap)
        #expect(ranges(map)[0] == [10, 40])
        map.moveEdge(.end, of: first, to: s(35), duration: song, snap: snap)
        map.moveEdge(.end, of: first, to: s(39.6), duration: song, snap: snap)
        #expect(ranges(map)[0] == [10, 40])
        map.moveEdge(.start, of: first, to: s(50), duration: song, snap: snap)
        #expect(ranges(map)[0] == [39.9, 40])
    }

    @Test func changingTheKindKeepsOnlyPinnedBeats() {
        var map = BeatMap.oneTempo(duration: song)
        map.sections[0].beats = [MappedBeat(time: s(1), isPinned: true), MappedBeat(time: s(2))]
        map.sections[0].isConfirmed = true
        map.setKind(of: map.sections[0].id, to: .ramp)
        #expect(map.sections[0].beats.count == 1)
        #expect(!map.sections[0].isConfirmed)
    }

    @Test func addedBeatsArePinnedAndNumberedFromTheBeatBefore() throws {
        var map = BeatMap(sections: [BeatSection(kind: .consistent, start: .zero, end: s(10), beatsPerMeasure: 3)])
        // Anchors in a section not filled yet are downbeats.
        map.addBeat(at: s(1), reach: snap)
        map.addBeat(at: s(4), reach: snap)
        let anchors: [Int] = map.sections[0].beats.map(\.position)
        #expect(anchors == [1, 1])

        map.sections[0].isConfirmed = true
        map.sections[0].beats = [1, 2, 3, 4].map { MappedBeat(time: s(Double($0)), isPinned: $0 == 1) }
        map.recountPositions()
        map.addBeat(at: s(2.5), reach: snap)
        let positions: [Int] = map.sections[0].beats.map(\.position)
        #expect(positions == [1, 2, 3, 1, 2])
        // Just past the end, the section grows to take it.
        let added = map.addBeat(at: s(10.2), reach: snap)
        let outside = try #require(added)
        #expect(map.sections[0].contains(outside))
        #expect(map.addBeat(at: s(20), reach: snap) == nil)
    }

    @Test func tappedBeatsKeepTheirCountThroughTheMeasure() {
        var map = BeatMap(sections: [BeatSection(kind: .ramp, start: .zero, end: s(10), beatsPerMeasure: 3)])
        for (index, seconds) in [1.0, 1.5, 2.0, 2.5].enumerated() {
            map.addBeat(at: s(seconds), reach: snap, position: index + 1)
        }
        // The fourth tap wraps round to 1, and every tap is pinned.
        let positions: [Int] = map.sections[0].beats.map(\.position)
        #expect(positions == [1, 2, 3, 1])
        let pinned = map.sections[0].beats.allSatisfy(\.isPinned)
        #expect(pinned)
    }

    @Test func movedBeatsArePinnedAndStayBetweenTheirNeighbours() {
        var map = BeatMap(sections: [BeatSection(kind: .consistent, start: .zero, end: s(10), isConfirmed: true, beats: [
            MappedBeat(time: s(1)), MappedBeat(time: s(2)), MappedBeat(time: s(3)),
        ])])
        let moved = map.moveBeat(at: s(2), to: s(2.01))
        #expect(moved == s(2.01))
        #expect(map.sections[0].beats[1].isPinned)
        let clamped = map.moveBeat(at: s(2.01), to: s(5))
        #expect(clamped.map { $0.seconds < 3 } == true)
    }

    @Test func onlyAMeasureThePersonSetIsMarkedAsSet() {
        var map = BeatMap.oneTempo(duration: song)
        #expect(!map.sections[0].isMeasureSet)
        map.setBeatsPerMeasure(of: map.sections[0].id, to: 4)
        #expect(map.sections[0].isMeasureSet)
    }

    @Test func settingAPositionRenumbersTheBeatsAfter() {
        var map = BeatMap(sections: [BeatSection(kind: .consistent, start: .zero, end: s(10), isConfirmed: true, beats:
            (0..<6).map { MappedBeat(time: s(Double($0)), isPinned: $0 == 0) }
        )])
        map.recountPositions()
        map.setPosition(of: s(3), to: 1)
        let positions: [Int] = map.sections[0].beats.map(\.position)
        #expect(positions == [1, 2, 3, 1, 2, 3])
    }

    @Test func copiedBeatsKeepTheirPlaceInTheMeasureAndTheBeatStays() throws {
        var map = BeatMap()
        map.drawSection(.consistent, from: s(0), to: s(20), duration: song, snap: .zero)
        map.addBeat(at: s(2), reach: s(1), position: 3)
        let copiedResult = map.copyBeat(at: s(2), to: s(9))
        let copied = try #require(copiedResult)
        #expect(map.beat(at: s(2)) != nil)
        #expect(map.beat(at: copied)?.position == 3 && map.beat(at: copied)?.isPinned == true)
        // Not onto another beat, nor outside every section.
        #expect(map.copyBeat(at: s(2), to: s(9)) == nil)
        #expect(map.copyBeat(at: s(2), to: s(50)) == nil)
    }

    @Test func copiedSectionsKeepKindLengthMeasureAndPinnedBeats() throws {
        var map = BeatMap()
        let drawn = map.drawSection(.consistent, from: s(10), to: s(20), duration: song, snap: .zero)
        let source = try #require(drawn)
        map.setBeatsPerMeasure(of: source, to: 3)
        map.addBeat(at: s(12), reach: s(1), position: 1)

        let copiedResult = map.copySection(source, to: s(40), duration: song)
        let copied = try #require(copiedResult)
        let copy = try #require(map.section(id: copied))
        #expect(copy.kind == .consistent && copy.start == s(40) && copy.end == s(50))
        #expect(copy.beatsPerMeasure == 3 && !copy.isConfirmed)
        #expect(copy.beats.map(\.time) == [s(42)])
        #expect(map.section(id: source)?.start == s(10))

        // Dropped late inside the source: just after it, cut short against the copy.
        let besideResult = map.copySection(source, to: s(18), duration: song)
        let beside = try #require(besideResult)
        #expect(map.section(id: beside)?.start == s(20) && map.section(id: beside)?.end == s(30))
    }
}
