import Foundation

/// The order the browser lists its clips in, and its timelines by name
/// when sorted by name, chosen in its view options. A video's scenes stay
/// in source order under it whatever the order of the clips.
enum BrowserSort: String, CaseIterable, Identifiable {
    /// As they were imported, the newest last.
    case added
    case name
    /// The longest first.
    case duration
    /// Video, then stills, then sound, each by name.
    case kind

    var id: Self { self }

    var title: String {
        switch self {
        case .added: "Date Added"
        case .name: "Name"
        case .duration: "Duration"
        case .kind: "Kind"
        }
    }

    /// `clips` in this order. Ties keep the order they were imported in.
    func ordered(_ clips: [MediaClip]) -> [MediaClip] {
        let added = Dictionary(uniqueKeysWithValues: clips.enumerated().map { ($0.element.id, $0.offset) })
        func byName(_ a: MediaClip, _ b: MediaClip) -> Bool? {
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? nil : order == .orderedAscending
        }
        func rank(_ kind: MediaKind) -> Int {
            switch kind {
            case .video: 0
            case .image: 1
            case .audio: 2
            }
        }
        return clips.sorted { a, b in
            let decided: Bool? = switch self {
            case .added: nil
            case .name: byName(a, b)
            case .duration: a.duration == b.duration ? nil : a.duration > b.duration
            case .kind: rank(a.kind) == rank(b.kind) ? byName(a, b) : rank(a.kind) < rank(b.kind)
            }
            return decided ?? ((added[a.id] ?? 0) < (added[b.id] ?? 0))
        }
    }

    /// Timelines in this order: by name when sorting by name, else as they
    /// were made (they have no length or kind to sort by).
    func ordered(_ timelineIDs: [UUID], in project: EditingProject) -> [UUID] {
        guard self == .name else { return timelineIDs }
        let names = Dictionary(uniqueKeysWithValues: timelineIDs.map { ($0, project.timeline(id: $0)?.name ?? "") })
        return timelineIDs.enumerated().sorted { a, b in
            let order = (names[a.element] ?? "").localizedStandardCompare(names[b.element] ?? "")
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)
    }
}
