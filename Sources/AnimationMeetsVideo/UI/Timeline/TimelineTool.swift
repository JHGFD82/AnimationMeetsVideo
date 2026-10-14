import Foundation

/// What dragging and clicking clips in the timeline does.
enum TimelineTool: String, CaseIterable, Identifiable {
    /// Select, move and trim clips.
    case arrow
    /// Click a clip to split it there.
    case blade
    /// Drag a clip to change which part of its footage it plays; its edges
    /// stay put unless the file runs out.
    case slip

    var id: Self { self }

    var name: String {
        switch self {
        case .arrow: "Arrow"
        case .blade: "Blade"
        case .slip: "Slip"
        }
    }

    var systemImage: String {
        switch self {
        case .arrow: "cursorarrow"
        case .blade: "scissors"
        case .slip: "film"
        }
    }

    /// P, S, R and T show transform properties, so slip is Y, as in Premiere.
    var shortcutKey: Character {
        switch self {
        case .arrow: "a"
        case .blade: "b"
        case .slip: "y"
        }
    }

    var help: String {
        switch self {
        case .arrow: "Arrow (A): select, move and trim clips"
        case .blade: "Blade (B): click a clip to split it"
        case .slip: "Slip (Y): drag a clip to change which part of its footage it plays"
        }
    }

    init?(shortcutKey: Character) {
        guard let match = Self.allCases.first(where: { $0.shortcutKey == shortcutKey }) else { return nil }
        self = match
    }
}
