import CoreMedia
import Foundation

/// A named stretch of a timeline, such as "Intro" or "Epilogue", shown in a
/// lane under the ruler. Sections don't overlap and land on frames. They
/// count toward the timeline's length, so a section past the last clip
/// makes the timeline longer (that stretch plays as black).
struct TimelineSection: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var start: CMTime
    var end: CMTime

    var duration: CMTime { CMTimeSubtract(end, start) }
}

/// Which end of a section is being dragged.
enum SectionEdge {
    case start, end
}

extension EditingProject {
    /// Length of a section made with a double-click.
    static let defaultSectionLength = CMTime(value: 5, timescale: 1)

    /// Adds a section over `start`–`end`, put on frames and cut to the gap
    /// between the sections it falls among, so none overlap. Named
    /// "Section N" unless a name is given. Returns its ID, or nil when there
    /// is less than a frame of room.
    @discardableResult
    mutating func addSection(named name: String? = nil, in timelineID: UUID, from start: CMTime, to end: CMTime) -> UUID? {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }) else { return nil }
        let timeline = timelines[tIndex]
        let frame = timeline.frameDuration
        let anchor = timeline.frameAligned(CMTimeMaximum(.zero, CMTimeMinimum(start, end)), .down)
        // The gap the start lands in: after the section before, up to the next.
        guard !timeline.sections.contains(where: { anchor >= $0.start && anchor < $0.end }) else { return nil }
        let previousEnd = timeline.sections.filter { $0.end <= anchor }.map(\.end).max() ?? .zero
        let nextStart = timeline.sections.filter { $0.start > anchor }.map(\.start).min() ?? .positiveInfinity
        let from = CMTimeMaximum(anchor, previousEnd)
        let wanted = timeline.frameAligned(CMTimeMaximum(start, end), .nearest)
        let to = CMTimeMinimum(CMTimeMaximum(wanted, CMTimeAdd(from, frame)), nextStart)
        guard CMTimeSubtract(to, from) >= frame else { return nil }
        let section = TimelineSection(name: name ?? "Section \(timeline.sections.count + 1)", start: from, end: to)
        timelines[tIndex].sections.append(section)
        timelines[tIndex].sections.sort { $0.start < $1.start }
        return section.id
    }

    mutating func renameSection(_ id: UUID, in timelineID: UUID, to name: String) {
        updateSection(id, in: timelineID) { $0.name = name }
    }

    mutating func deleteSection(_ id: UUID, in timelineID: UUID) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }) else { return }
        timelines[tIndex].sections.removeAll { $0.id == id }
    }

    /// The section moved to start at `proposedStart`, keeping its length:
    /// on a frame, not before zero, and within the gap between its
    /// neighbors (it doesn't jump over them).
    func resolvedSectionMove(_ id: UUID, in timelineID: UUID, to proposedStart: CMTime) -> TimelineSection? {
        guard let (timeline, section, previousEnd, nextStart) = sectionContext(id, in: timelineID) else { return nil }
        let latest = CMTimeSubtract(nextStart, section.duration)
        let start = CMTimeMinimum(CMTimeMaximum(timeline.frameAligned(proposedStart, .nearest), previousEnd), latest)
        var moved = section
        moved.start = start
        moved.end = CMTimeAdd(start, section.duration)
        return moved
    }

    mutating func moveSection(_ id: UUID, in timelineID: UUID, to start: CMTime) {
        guard let moved = resolvedSectionMove(id, in: timelineID, to: start) else { return }
        updateSection(id, in: timelineID) { $0 = moved }
    }

    /// The section with one end dragged to `proposed`: on a frame, at least
    /// a frame long, and not past its neighbor on that side (or zero).
    func resolvedSectionEdge(_ id: UUID, edge: SectionEdge, in timelineID: UUID, to proposed: CMTime) -> TimelineSection? {
        guard let (timeline, section, previousEnd, nextStart) = sectionContext(id, in: timelineID) else { return nil }
        let frame = timeline.frameDuration
        let time = timeline.frameAligned(proposed, .nearest)
        var resized = section
        switch edge {
        case .start:
            resized.start = CMTimeMinimum(CMTimeMaximum(time, previousEnd), CMTimeSubtract(section.end, frame))
        case .end:
            resized.end = CMTimeMaximum(CMTimeMinimum(time, nextStart), CMTimeAdd(section.start, frame))
        }
        return resized
    }

    mutating func setSectionEdge(_ id: UUID, edge: SectionEdge, in timelineID: UUID, to time: CMTime) {
        guard let resized = resolvedSectionEdge(id, edge: edge, in: timelineID, to: time) else { return }
        updateSection(id, in: timelineID) { $0 = resized }
    }

    private func sectionContext(_ id: UUID, in timelineID: UUID)
        -> (timeline: Timeline, section: TimelineSection, previousEnd: CMTime, nextStart: CMTime)?
    {
        guard let timeline = timeline(id: timelineID),
              let section = timeline.sections.first(where: { $0.id == id })
        else {
            return nil
        }
        let others = timeline.sections.filter { $0.id != id }
        let previousEnd = others.filter { $0.end <= section.start }.map(\.end).max() ?? .zero
        let nextStart = others.filter { $0.start >= section.end }.map(\.start).min() ?? .positiveInfinity
        return (timeline, section, previousEnd, nextStart)
    }

    private mutating func updateSection(_ id: UUID, in timelineID: UUID, _ change: (inout TimelineSection) -> Void) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let sIndex = timelines[tIndex].sections.firstIndex(where: { $0.id == id })
        else {
            return
        }
        change(&timelines[tIndex].sections[sIndex])
        timelines[tIndex].sections.sort { $0.start < $1.start }
    }
}
