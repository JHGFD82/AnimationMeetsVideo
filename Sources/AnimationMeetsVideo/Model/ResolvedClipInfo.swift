import CoreMedia
import Foundation

/// What a `TimelineClip` resolves to, for display and playback.
enum ResolvedClipInfo {
    case media(MediaClip)
    case timeline(Timeline)
    case adjustment
    case graphic

    var name: String {
        switch self {
        case .media(let clip): clip.name
        case .timeline(let timeline): timeline.name
        case .adjustment: "Adjustment"
        case .graphic: "Shapes"
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
        case .graphic: "Shapes · draws the shapes in its effects"
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
