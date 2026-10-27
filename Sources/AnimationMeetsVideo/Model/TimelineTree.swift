import CoreMedia
import Foundation

// Timelines inside timelines, as the browser's Timelines tab shows them,
// and duplicating a timeline.

extension EditingProject {
    /// The timelines `timelineID` embeds directly as clips, each once, in
    /// the order they first appear from the top layer down.
    func embeddedTimelines(in timelineID: UUID) -> [UUID] {
        guard let timeline = timeline(id: timelineID) else { return [] }
        var found: [UUID] = []
        for layer in timeline.layers {
            for clip in layer.clips {
                if case .timeline(let nestedID) = clip.source, !found.contains(nestedID), self.timeline(id: nestedID) != nil {
                    found.append(nestedID)
                }
            }
        }
        return found
    }

    /// The timelines `timelineID` is inside, outermost first, as the
    /// Timelines tab lists it: each nested timeline under the timeline
    /// nearest the top that embeds it. Empty for a timeline nothing
    /// embeds. The breadcrumb of a timeline opened other than from its clip.
    func containingTimelines(of timelineID: UUID) -> [UUID] {
        // Breadth first from the top, so each goes to its shallowest
        // parent; claiming each once also stops a cycle.
        let top = topLevelTimelines
        var claimed = Set(top)
        var parents: [UUID: UUID] = [:]
        var queue = top[...]
        while let parent = queue.popFirst() {
            for child in embeddedTimelines(in: parent) where !claimed.contains(child) {
                claimed.insert(child)
                parents[child] = parent
                queue.append(child)
            }
        }
        var path: [UUID] = []
        var current = timelineID
        while let parent = parents[current] {
            path.insert(parent, at: 0)
            current = parent
        }
        return path
    }

    /// `timelineID` and every timeline its picture or sound is drawn from,
    /// however deep: those it embeds as clips, and those its clips' effects
    /// take as inputs. A preview of it changes only when one of these does.
    func timelinesDrawn(from timelineID: UUID) -> Set<UUID> {
        var found: Set<UUID> = []
        var queue = [timelineID]
        while let id = queue.popLast() {
            guard !found.contains(id), let timeline = timeline(id: id) else { continue }
            found.insert(id)
            for layer in timeline.layers {
                for clip in layer.clips {
                    if case .timeline(let nestedID) = clip.source { queue.append(nestedID) }
                    for effect in clip.effects {
                        if case .timeline(let inputID) = effect.input?.source { queue.append(inputID) }
                    }
                }
            }
        }
        return found
    }

    /// The stretches of `timelineID` (in its own time) that clips embedding
    /// it play, in any timeline, in no particular order: what the browser
    /// underlines, as it does the media timelines use.
    func usedRanges(ofTimeline timelineID: UUID) -> [CMTimeRange] {
        timelines.flatMap { timeline in
            timeline.layers.flatMap { layer in
                layer.clips.compactMap { clip -> CMTimeRange? in
                    guard case .timeline(let nestedID) = clip.source, nestedID == timelineID else { return nil }
                    return CMTimeRange(start: clip.trimStart, end: clip.trimEnd)
                }
            }
        }
    }

    /// The timelines no other timeline embeds, the main one first: the top
    /// of the Timelines tab, with what each embeds under it.
    var topLevelTimelines: [UUID] {
        let embedded = Set(timelines.flatMap { embeddedTimelines(in: $0.id) })
        let others = timelines.map(\.id).filter { !embedded.contains($0) && $0 != rootTimelineID }
        return (timeline(id: rootTimelineID) == nil ? [] : [rootTimelineID]) + others
    }

    /// Puts a copy of a timeline right after it, named as the Finder names
    /// a copy, with new IDs for it, its layers and its clips (see
    /// `TimelineClip.duplicated()`). An adjustment clip that reached a layer
    /// reaches that layer's copy. Timelines it embeds are shared, not
    /// copied, as clips of them anywhere else are. Returns the copy's ID.
    @discardableResult
    mutating func duplicateTimeline(_ timelineID: UUID) -> UUID? {
        guard let index = timelines.firstIndex(id: timelineID) else { return nil }
        var copy = timelines[index]
        copy.id = UUID()
        copy.name = Self.copyName(of: copy.name, among: timelines.map(\.name))
        var layerIDs: [UUID: UUID] = [:]
        for l in copy.layers.indices {
            let newID = UUID()
            layerIDs[copy.layers[l].id] = newID
            copy.layers[l].id = newID
            copy.layers[l].clips = copy.layers[l].clips.map { $0.duplicated() }
            copy.layers[l].audioEffects = copy.layers[l].audioEffects.map { $0.duplicated() }
        }
        for l in copy.layers.indices {
            for c in copy.layers[l].clips.indices {
                if let reach = copy.layers[l].clips[c].reach { copy.layers[l].clips[c].reach = layerIDs[reach] }
            }
        }
        copy.sections = copy.sections.map { section in
            var renewed = section
            renewed.id = UUID()
            return renewed
        }
        timelines.insert(copy, at: index + 1)
        return copy.id
    }

    /// "Main copy", then "Main copy 2" and on, as the Finder does.
    static func copyName(of name: String, among taken: [String]) -> String {
        let first = "\(name) copy"
        guard taken.contains(first) else { return first }
        var number = 2
        while taken.contains("\(first) \(number)") { number += 1 }
        return "\(first) \(number)"
    }
}
