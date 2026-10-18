import CoreMedia
import SwiftUI

/// Everything that affects the rendered composition. Layer renames, section
/// names and timeline names are stripped so they don't swap the player item and
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
                // Volume and pan are applied as the sound plays
                // (`AudioLevelTap`), without rebuilding the player. Only
                // whether a clip has either of its own counts: that puts
                // its sound on a track of its own, which the player has to
                // be rebuilt for.
                copy.layers[index].volume = AnimatedValue(0.0)
                copy.layers[index].pan = AnimatedValue(0.0)
                for clip in copy.layers[index].clips.indices {
                    let hasOwn = copy.layers[index].clips[clip].hasOwnMix
                    copy.layers[index].clips[clip].volume = AnimatedValue(hasOwn ? 1.0 : 0.0)
                    copy.layers[index].clips[clip].pan = AnimatedValue(0.0)
                }
            }
            for index in copy.sections.indices {
                copy.sections[index].name = ""
            }
            return copy
        }
        media = project.clips.map {
            Media(id: $0.id, path: $0.url?.path, offset: $0.alignmentOffset, stamp: $0.acceptedStamp)
        }
    }
}

extension CompositionKey {
    /// Whether the only difference from `old` is clips' speed (and the
    /// clips after them moving to follow it). What speed changes is which
    /// frames play when, which only playing shows, so a drag of it doesn't
    /// need the picture updated as it goes.
    func differsOnlyInSpeed(from old: CompositionKey) -> Bool {
        guard timelines.count == old.timelines.count, media == old.media else { return false }
        func neutral(_ timelines: [Timeline]) -> [Timeline] {
            timelines.map { timeline in
                var copy = timeline
                for layer in copy.layers.indices {
                    for clip in copy.layers[layer].clips.indices {
                        copy.layers[layer].clips[clip].time.speed = AnimatedValue(100.0)
                        copy.layers[layer].clips[clip].startOffset = .zero
                    }
                }
                return copy
            }
        }
        return neutral(timelines) == neutral(old.timelines)
    }
}
