import CoreMedia
import SwiftUI

/// Everything that affects the rendered composition. Layer renames and
/// timeline names are stripped so they don't swap the player item and
/// interrupt playback; a replaced file or a new alignment is included so
/// they do.
struct CompositionKey: Equatable {
    struct Media: Equatable {
        var id: UUID
        var path: String?
        var offset: CMTime
        var stamp: FileStamp?
    }

    var timelines: [Timeline]
    var media: [Media]

    init(project: EditingProject) {
        timelines = project.timelines.map { timeline in
            var copy = timeline
            copy.name = ""
            for index in copy.layers.indices {
                copy.layers[index].customName = nil
            }
            return copy
        }
        media = project.clips.map {
            Media(id: $0.id, path: $0.url?.path, offset: $0.alignmentOffset, stamp: $0.acceptedStamp)
        }
    }
}
