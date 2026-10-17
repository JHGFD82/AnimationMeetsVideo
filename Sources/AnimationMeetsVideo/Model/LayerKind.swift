import CoreMedia
import Foundation

/// What a layer holds, which decides the area of the timeline it sits in:
/// video at the top, sound in the middle, music at the bottom.
///
/// Sound and music are both audio and play the same way; the split is for
/// the person editing, so dialogue and effects can be kept apart from the
/// score. A clip with pictures only goes on a video layer, and a clip that
/// is only sound only goes on a sound or music layer.
enum LayerKind: String, CaseIterable, Identifiable {
    case video, sound, music

    var id: Self { self }

    var name: String {
        switch self {
        case .video: "Video"
        case .sound: "Sound"
        case .music: "Music"
        }
    }

    var isAudio: Bool { self != .video }
}

extension EditingProject {
    /// Whether a clip can go on a layer of `kind`: pictures on video layers,
    /// sound alone on sound or music layers.
    func layerKind(_ kind: LayerKind, accepts clip: TimelineClip) -> Bool {
        isAudioOnly(clip) == kind.isAudio
    }

    /// Whether a layer takes a clip: its kind does, and an adjustment layer
    /// takes only adjustment clips, which no other layer takes.
    func layer(_ layer: TimelineLayer, accepts clip: TimelineClip) -> Bool {
        layer.isAdjustment == (clip.source == .adjustment) && layerKind(layer.kind, accepts: clip)
    }

    /// A clip of sound alone: an audio file, or sound detached from a video.
    /// Decided by what the clip is, not by whether its file has a sound
    /// track, so a silent audio file still belongs on an audio layer.
    func isAudioOnly(_ clip: TimelineClip) -> Bool {
        switch resolvedInfo(for: clip.source) {
        case .media(let media): media.kind == .audio || clip.streams == .audio
        case .timeline, .adjustment, nil: false
        }
    }

    /// The kind of layer an asset goes on when nothing says otherwise:
    /// audio files are taken to be sound, everything else is video. Music
    /// is analyzed for beats, so only the person puts audio there.
    func defaultLayerKind(forAsset assetID: UUID) -> LayerKind {
        mediaClip(id: assetID)?.kind == .audio ? .sound : .video
    }

    /// Assets with a clip on a Music layer of any timeline: the ones whose
    /// beats are found.
    var assetsOnMusicLayers: Set<UUID> {
        var ids: Set<UUID> = []
        for timeline in timelines {
            for layer in timeline.layers where layer.kind == .music {
                for clip in layer.clips {
                    if case .media(let id) = clip.source { ids.insert(id) }
                }
            }
        }
        return ids
    }

    /// The kind a layer saved before layers had kinds must have been, from
    /// its clips: video if any has pictures (or it has none), sound if it
    /// holds sound detached from video, otherwise music.
    func inferredKind(of layer: TimelineLayer) -> LayerKind {
        let audioOnly = layer.clips.filter(isAudioOnly)
        guard !layer.clips.isEmpty, audioOnly.count == layer.clips.count else { return .video }
        let detached = audioOnly.contains { clip in
            guard case .media(let media) = resolvedInfo(for: clip.source) else { return false }
            return media.kind == .video
        }
        return detached ? .sound : .music
    }

    /// Gives the layers in `ids` the kind their clips imply. For projects
    /// saved before layers had kinds.
    mutating func inferLayerKinds(of ids: Set<UUID>) {
        for t in timelines.indices {
            for l in timelines[t].layers.indices where ids.contains(timelines[t].layers[l].id) {
                timelines[t].layers[l].kind = inferredKind(of: timelines[t].layers[l])
            }
        }
    }

    /// Moves a clip onto a new layer of `kind` at the top of the stack,
    /// keeping its time, as when it is dropped on the "new layer" zone.
    /// Returns the new layer, or nil if the clip can't go on that kind.
    @discardableResult
    mutating func moveClipToNewLayer(_ id: UUID, in timelineID: UUID, layer layerID: UUID, kind: LayerKind) -> UUID? {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(where: { $0.id == id }),
              layerKind(kind, accepts: timelines[tIndex].layers[lIndex].clips[cIndex])
        else {
            return nil
        }
        let clip = timelines[tIndex].layers[lIndex].clips.remove(at: cIndex)
        var layer = TimelineLayer(customName: nil, kind: kind, clips: [clip])
        layer.isAdjustment = clip.source == .adjustment
        timelines[tIndex].layers.insert(layer, at: 0)
        return layer.id
    }

    /// The layers of one kind, top to bottom.
    func layers(of kind: LayerKind, in timeline: Timeline) -> [TimelineLayer] {
        timeline.layers.filter { $0.kind == kind }
    }
}
