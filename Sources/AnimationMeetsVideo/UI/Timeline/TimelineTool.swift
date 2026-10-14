import Foundation

/// What dragging and clicking clips in the timeline does.
enum TimelineTool: String, CaseIterable, Identifiable {
    /// Select, move and trim clips.
    case arrow
    /// Click a clip to split it there.
    case blade
    /// Drag a clip's edge to trim it and move everything after it on its
    /// layer by as much.
    case ripple

    var id: Self { self }

    var name: String {
        switch self {
        case .arrow: "Arrow"
        case .blade: "Blade"
        case .ripple: "Ripple"
        }
    }

    var systemImage: String {
        switch self {
        case .arrow: "cursorarrow"
        case .blade: "scissors"
        case .ripple: "arrow.left.and.line.vertical.and.arrow.right"
        }
    }

    /// P, S, R and T show transform properties, so ripple is E.
    var shortcutKey: Character {
        switch self {
        case .arrow: "a"
        case .blade: "b"
        case .ripple: "e"
        }
    }

    var help: String {
        switch self {
        case .arrow: "Arrow (A): select, move and trim clips"
        case .blade: "Blade (B): click a clip to split it"
        case .ripple: "Ripple (E): drag a clip's edge to trim it and move everything after it"
        }
    }

    init?(shortcutKey: Character) {
        guard let match = Self.allCases.first(where: { $0.shortcutKey == shortcutKey }) else { return nil }
        self = match
    }
}
