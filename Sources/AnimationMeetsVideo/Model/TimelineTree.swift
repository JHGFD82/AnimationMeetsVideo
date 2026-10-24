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
