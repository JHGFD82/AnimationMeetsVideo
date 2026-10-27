import CoreMedia
import Foundation

/// What a `TimelineClip` resolves to, for display and playback.
enum ResolvedClipInfo: Equatable {
    case media(MediaClip)
    case timeline(Timeline)
    case adjustment
    /// With `title`, the words of its first Text effect (see
    /// `EditingProject.textTitle(of:)`), which name it.
    case graphic(title: String?)

    var name: String {
        switch self {
        case .media(let clip): clip.name
        case .timeline(let timeline): timeline.name
        case .adjustment: "Adjustment"
        case .graphic(let title): title ?? "Shapes"
        }
    }

    var systemImage: String {
        switch self {
        case .media(let clip): clip.kind.systemImage
        case .timeline: "rectangle.stack"
        case .adjustment: "slider.horizontal.below.rectangle"
        case .graphic: "square.on.circle"
        }
    }

    var summary: String {
        switch self {
        case .media(let clip): clip.formatSummary
        case .timeline(let timeline): "Nested Timeline · \(timeline.timebaseSummary)"
        case .adjustment: "Adjustment · applies its effects to the layers below"
        case .graphic(let title): title == nil ? "Shapes · draws the shapes in its effects" : "Text · draws the text and shapes in its effects"
        }
    }

    var isHDR: Bool {
        switch self {
        case .media(let clip): clip.colorSpace.isHDR
        case .timeline(let timeline): timeline.colorSpace.isHDR
        case .adjustment, .graphic: false
        }
    }
}
