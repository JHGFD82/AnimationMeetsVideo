import SwiftUI

extension BeatSection.Kind {
    /// The kind's colour in the beat match panel, so the kinds tell apart
    /// at a glance: the timeline's section bronze for consistent sections,
    /// a violet for ramps, and grey for what isn't analyzed.
    var tone: Color {
        switch self {
        case .consistent: Design.section
        case .ramp: Design.hex(0x9C72C2)
        case .none: Design.ClipTone.unknown.color
        }
    }
}
