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
    /// The crossfade shape of joined cuts whose transitions don't choose
    /// one: it is in the fades the tracks are built with.
    var jointAudioCrossfade: AudioCrossfade

    init(project: EditingProject) {
        jointAudioCrossfade = project.jointAudioCrossfade
        timelines = project.timelines.map { timeline in
            var copy = timeline
            copy.name = ""
            for index in copy.layers.indices {
                copy.layers[index].customName = nil
                // Volume, pan and sound effects' settings are applied as
                // the sound plays (`AudioLevelTap`), without rebuilding the
                // player (every clip's sound is on a track of its own, so a
                // clip's volume crossing 0 dB changes nothing). What counts
                // is whether a pan is off center, which plays mono sound
                // from a stereo copy, and which effects its tap runs: the
                // player has to be rebuilt for those.
                func panned(_ pan: AnimatedValue<Double>) -> AnimatedValue<Double> {
                    AnimatedValue(pan == AnimatedValue(0.0) ? 0.0 : 1.0)
                }
                copy.layers[index].volume = AnimatedValue(0.0)
                copy.layers[index].pan = panned(copy.layers[index].pan)
                copy.layers[index].audioEffects = copy.layers[index].audioEffects
                    .filter(\.enabled).map { Effect(id: $0.id, kind: $0.kind, controls: []) }
                for clip in copy.layers[index].clips.indices {
                    copy.layers[index].clips[clip].volume = AnimatedValue(0.0)
                    copy.layers[index].clips[clip].pan = panned(copy.layers[index].clips[clip].pan)
                    copy.layers[index].clips[clip].audioEffects = copy.layers[index].clips[clip].audioEffects
                        .filter(\.enabled).map { Effect(id: $0.id, kind: $0.kind, controls: []) }
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
        guard timelines.count == old.timelines.count, media == old.media, jointAudioCrossfade == old.jointAudioCrossfade else { return false }
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

/// What the viewer's player item has to be built again for: the
/// composition (`CompositionKey`) without what the compositor takes as each
/// frame is drawn (`LiveValues`), which is every clip's effects' values and
/// anchor point. Two projects with the same key play the same item, the
/// values patched in; one that differs (a clip added, moved, trimmed or
/// retimed, a transition, the layers' order, a replaced file, an effect
/// added, removed or turned off, a pan moved off center) is built again.
struct StructureKey: Equatable {
    private var composition: CompositionKey

    init(project: EditingProject) {
        composition = CompositionKey(project: project)
        for t in composition.timelines.indices {
            for l in composition.timelines[t].layers.indices {
                for c in composition.timelines[t].layers[l].clips.indices {
                    composition.timelines[t].layers[l].clips[c].effects =
                        composition.timelines[t].layers[l].clips[c].effects.map(Effect.bare)
                    composition.timelines[t].layers[l].clips[c].anchorPoint = AnimatedValue(.zero)
                }
            }
        }
    }

    /// Whether the only difference from `old` is clips' speed (and the
    /// clips after them moving to follow it), which only playing shows.
    func differsOnlyInSpeed(from old: StructureKey) -> Bool {
        composition.differsOnlyInSpeed(from: old.composition)
    }
}
