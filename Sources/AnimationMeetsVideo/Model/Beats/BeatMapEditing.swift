import CoreMedia
import Foundation

/// The edits the beat match panel makes to a beat map: drawing and
/// resizing sections, and placing, moving and numbering beats. See
/// docs/beat-matching.md. Times are in the asset's original time.
extension BeatMap {
    enum Edge { case start, end }

    /// The shortest section that can be drawn or resized to.
    static let shortestSection = CMTime(value: 1, timescale: 10)

    /// One consistent section over the whole song, for a song of one tempo.
    static func oneTempo(duration: CMTime) -> BeatMap {
        BeatMap(sections: [BeatSection(kind: .consistent, start: .zero, end: duration)])
    }

    func sectionIndex(containing time: CMTime) -> Int? {
        sections.firstIndex { $0.contains(time) }
    }

    /// The unmarked stretch around `time`: from the nearest section edge (or
    /// the start of the song) before it to the nearest one (or the end)
    /// after it. Nil when `time` is inside a section.
    func gap(around time: CMTime, duration: CMTime) -> CMTimeRange? {
        guard sectionIndex(containing: time) == nil else { return nil }
        let start = sections.last { CMTimeCompare($0.end, time) <= 0 }?.end ?? .zero
        let end = sections.first { CMTimeCompare($0.start, time) > 0 }?.start ?? duration
        guard CMTimeCompare(start, end) < 0 else { return nil }
        return CMTimeRange(start: start, end: end)
    }

    /// Draws a section of `kind` across `from`...`to` (either order), in the
    /// unmarked stretch around `gapAt` (by default `from`, which must then
    /// be on unmarked song). It stops at the sections either side, and an
    /// end within `snap` of a neighbour (or the song's start or end) clicks
    /// in against it. Gives the new section's ID, or nil when there is no
    /// room. A drag that started in a gap passes where it started as
    /// `gapAt`, so a start that snapped onto the next section's edge still
    /// draws in that gap.
    @discardableResult
    mutating func drawSection(
        _ kind: BeatSection.Kind, from: CMTime, to: CMTime, in gapAt: CMTime? = nil, duration: CMTime, snap: CMTime
    ) -> UUID? {
        guard let gap = gap(around: gapAt ?? from, duration: duration) else { return nil }
        var start = CMTimeMaximum(CMTimeMinimum(from, to), gap.start)
        var end = CMTimeMinimum(CMTimeMaximum(from, to), gap.end)
        if CMTimeCompare(CMTimeSubtract(start, gap.start), snap) <= 0 { start = gap.start }
        if CMTimeCompare(CMTimeSubtract(gap.end, end), snap) <= 0 { end = gap.end }
        guard CMTimeCompare(CMTimeSubtract(end, start), Self.shortestSection) >= 0 else { return nil }
        let section = BeatSection(kind: kind, start: start, end: end)
        sections.append(section)
        sections.sort { CMTimeCompare($0.start, $1.start) < 0 }
        return section.id
    }

    /// Fills the unmarked stretch around `time` with a section of `kind`,
    /// like a paint bucket; inside a section, changes its kind instead.
    /// Gives the section's ID.
    @discardableResult
    mutating func fill(at time: CMTime, with kind: BeatSection.Kind, duration: CMTime) -> UUID? {
        if let index = sectionIndex(containing: time) {
            setKind(of: sections[index].id, to: kind)
            return sections[index].id
        }
        guard let gap = gap(around: time, duration: duration),
              CMTimeCompare(gap.duration, Self.shortestSection) >= 0
        else { return nil }
        return drawSection(kind, from: gap.start, to: gap.end, duration: duration, snap: .zero)
    }

    /// Moves one edge of a section, never past a neighbour or closer than
    /// `shortestSection` to its other edge. Within `snap` of a neighbour's
    /// edge (or the song's start or end) it clicks in against it.
    mutating func moveEdge(_ edge: Edge, of id: UUID, to time: CMTime, duration: CMTime, snap: CMTime) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let section = sections[index]
        switch edge {
        case .start:
            let limit = index > 0 ? sections[index - 1].end : .zero
            var start = CMTimeMaximum(time, limit)
            if CMTimeCompare(CMTimeSubtract(start, limit), snap) <= 0 { start = limit }
            start = CMTimeMinimum(start, CMTimeSubtract(section.end, Self.shortestSection))
            sections[index].start = CMTimeMaximum(start, limit)
        case .end:
            let limit = index + 1 < sections.count ? sections[index + 1].start : duration
            var end = CMTimeMinimum(time, limit)
            if CMTimeCompare(CMTimeSubtract(limit, end), snap) <= 0 { end = limit }
            end = CMTimeMaximum(end, CMTimeAdd(section.start, Self.shortestSection))
            sections[index].end = CMTimeMinimum(end, limit)
        }
    }

    /// Changes a section's kind. Its filled beats are another kind's, so
    /// they go, and it waits to be filled again; pinned beats stay.
    mutating func setKind(of id: UUID, to kind: BeatSection.Kind) {
        updateSection(id) { section in
            guard section.kind != kind else { return }
            section.kind = kind
            section.beats = section.pinnedBeats
            section.isConfirmed = false
        }
    }

    /// Readies a consistent section to be filled at another's copied
    /// details: it takes their beats per measure and steadiness, its start
    /// is taken to be beat 1, pinned, and the beats it had go. The fill at
    /// the copied tempo does the rest. Gives false, changing nothing, for
    /// any other kind.
    @discardableResult
    mutating func paste(_ details: BeatSectionDetails, into id: UUID) -> Bool {
        guard section(id: id)?.kind == .consistent else { return false }
        updateSection(id) { section in
            section.beatsPerMeasure = details.beatsPerMeasure
            section.isMeasureSet = details.isMeasureSet
            section.steadiness = details.steadiness
            section.beats = [MappedBeat(time: section.start, position: 1, isPinned: true)]
            section.isConfirmed = false
        }
        recountPositions()
        return true
    }

    mutating func removeSection(_ id: UUID) {
        sections.removeAll { $0.id == id }
        recountPositions()
    }

    // MARK: Beats

    /// Where the beat at exactly `time` is: its section and index there.
    func beatIndex(at time: CMTime) -> (section: Int, beat: Int)? {
        for (sectionIndex, section) in sections.enumerated() {
            if let beat = section.beats.firstIndex(where: { CMTimeCompare($0.time, time) == 0 }) {
                return (sectionIndex, beat)
            }
        }
        return nil
    }

    func beat(at time: CMTime) -> MappedBeat? {
        beatIndex(at: time).map { sections[$0.section].beats[$0.beat] }
    }

    /// The beat nearest `time`, within `reach`, from any section.
    func nearestBeat(to time: CMTime, within reach: CMTime) -> MappedBeat? {
        sections.flatMap(\.beats)
            .filter { CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract($0.time, time)), reach) <= 0 }
            .min { CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract($0.time, time)), CMTimeAbsoluteValue(CMTimeSubtract($1.time, time))) < 0 }
    }

    /// Adds a pinned beat. It goes into the section it falls in, or, just
    /// past a section's edge, into that section, which grows to take it.
    /// An anchor in a section not filled yet is a downbeat; in a filled one
    /// it takes the place after the beat before it. Gives the beat's time,
    /// or nil outside every section.
    @discardableResult
    mutating func addBeat(at time: CMTime, reach: CMTime) -> CMTime? {
        let index = sectionIndex(containing: time) ?? sections.indices.min { a, b in
            distance(from: time, to: sections[a]) < distance(from: time, to: sections[b])
        }.flatMap { CMTimeCompare(distance(from: time, to: sections[$0]), reach) <= 0 ? $0 : nil }
        guard let index, sections[index].kind != .none, beat(at: time) == nil else { return nil }
        var section = sections[index]
        if CMTimeCompare(time, section.start) < 0 { section.start = time }
        if CMTimeCompare(time, section.end) >= 0 { section.end = CMTimeAdd(time, CMTime(value: 1, timescale: 1000)) }
        var beat = MappedBeat(time: time, position: 1, isPinned: true)
        if section.isConfirmed {
            if let before = section.beats.last(where: { CMTimeCompare($0.time, time) < 0 }) {
                beat.position = before.position.modulo(section.beatsPerMeasure) + 1
            } else if let after = section.beats.first {
                beat.position = (after.position - 2).modulo(section.beatsPerMeasure) + 1
            }
        }
        section.beats.append(beat)
        section.normalize()
        sections[index] = section
        recountPositions()
        return time
    }

    private func distance(from time: CMTime, to section: BeatSection) -> CMTime {
        if CMTimeCompare(time, section.start) < 0 { return CMTimeSubtract(section.start, time) }
        if CMTimeCompare(time, section.end) >= 0 { return CMTimeSubtract(time, section.end) }
        return .zero
    }

    /// Moves a beat, which pins it, keeping it in its section and short of
    /// the beats either side. Gives where it ended up.
    @discardableResult
    mutating func moveBeat(at time: CMTime, to target: CMTime) -> CMTime? {
        guard let (sectionIndex, beatIndex) = beatIndex(at: time) else { return nil }
        var section = sections[sectionIndex]
        let tick = CMTime(value: 1, timescale: max(target.timescale, 1000))
        var low = section.start, high = CMTimeSubtract(section.end, tick)
        if beatIndex > 0 { low = CMTimeMaximum(low, CMTimeAdd(section.beats[beatIndex - 1].time, tick)) }
        if beatIndex + 1 < section.beats.count { high = CMTimeMinimum(high, CMTimeSubtract(section.beats[beatIndex + 1].time, tick)) }
        guard CMTimeCompare(low, high) <= 0 else { return time }
        let moved = CMTimeMinimum(CMTimeMaximum(target, low), high)
        section.beats[beatIndex].time = moved
        section.beats[beatIndex].isPinned = true
        sections[sectionIndex] = section
        return moved
    }

    mutating func removeBeat(at time: CMTime) {
        guard let (sectionIndex, beatIndex) = beatIndex(at: time) else { return }
        sections[sectionIndex].beats.remove(at: beatIndex)
        recountPositions()
    }

    /// Says which beat of its measure a beat is, which pins it; the beats
    /// after it count on from there.
    mutating func setPosition(of time: CMTime, to position: Int) {
        guard let (sectionIndex, beatIndex) = beatIndex(at: time) else { return }
        let measure = sections[sectionIndex].beatsPerMeasure
        sections[sectionIndex].beats[beatIndex].position = (position - 1).modulo(measure) + 1
        sections[sectionIndex].beats[beatIndex].isPinned = true
        recountPositions()
    }

    /// Lets a pinned beat be moved by analysis again.
    mutating func unpin(at time: CMTime) {
        guard let (sectionIndex, beatIndex) = beatIndex(at: time) else { return }
        sections[sectionIndex].beats[beatIndex].isPinned = false
    }

    /// Sets a section's beats per measure and renumbers.
    mutating func setBeatsPerMeasure(of id: UUID, to count: Int) {
        updateSection(id) { section in
            section.beatsPerMeasure = count
            section.isMeasureSet = true
        }
        recountPositions()
    }
}

/// What a filled consistent section passes to another by copy and paste:
/// its tempo and how it counts its measures. Ramps change tempo, so they
/// have nothing to pass on.
struct BeatSectionDetails: Equatable, Sendable {
    /// Beats per minute.
    var tempo: Double
    var beatsPerMeasure: Int
    var isMeasureSet: Bool
    var steadiness: BeatSection.Steadiness
}
