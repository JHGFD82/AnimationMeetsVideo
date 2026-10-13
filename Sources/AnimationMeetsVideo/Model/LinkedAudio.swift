import CoreMedia
import Foundation

// MARK: - Streams

extension EditingProject {
    /// Whether the clip draws pictures: video it hasn't had its picture
    /// taken from, and nested timelines.
    func playsVideo(_ clip: TimelineClip) -> Bool {
        switch resolvedInfo(for: clip.source) {
        case .media(let media): media.kind == .video && clip.streams != .audio
        case .timeline: true
        case nil: false
        }
    }

    /// Whether the clip makes sound: audio files, videos with sound whose
    /// audio wasn't detached, and nested timelines.
    func playsAudio(_ clip: TimelineClip) -> Bool {
        switch resolvedInfo(for: clip.source) {
        case .media(let media): media.hasAudio && clip.streams != .video
        case .timeline: true
        case nil: false
        }
    }

    /// True for a video clip still carrying its own sound, which the
    /// timeline can show expanded and detach.
    func hasLinkedAudio(_ clip: TimelineClip) -> Bool {
        guard case .media(let media) = resolvedInfo(for: clip.source) else { return false }
        return media.kind == .video && media.hasAudio && clip.streams == .videoAndAudio
    }

    func layerHasLinkedAudio(_ layer: TimelineLayer) -> Bool {
        layer.clips.contains { hasLinkedAudio($0) }
    }

    /// Separates the sound from video clips on a layer: the clips keep only
    /// their picture, and their sound goes onto a new layer just below with
    /// the same timing and trims, so it plays exactly as before but can be
    /// moved, trimmed or deleted on its own. `clipIDs` limits it to those
    /// clips; nil detaches every linked clip on the layer. Returns the new
    /// layer, or nil when there was nothing to detach.
    @discardableResult
    mutating func detachAudio(of clipIDs: Set<UUID>? = nil, in timelineID: UUID, layer layerID: UUID) -> UUID? {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return nil
        }
        var audioClips: [TimelineClip] = []
        for cIndex in timelines[tIndex].layers[lIndex].clips.indices {
            let clip = timelines[tIndex].layers[lIndex].clips[cIndex]
            guard clipIDs?.contains(clip.id) ?? true, hasLinkedAudio(clip) else { continue }
            timelines[tIndex].layers[lIndex].clips[cIndex].streams = .video
            var audio = clip
            audio.id = UUID()
            audio.streams = .audio
            audio.autoMatteEnabled = false
            audioClips.append(audio)
        }
        guard !audioClips.isEmpty else { return nil }
        let layer = TimelineLayer(customName: nil, clips: audioClips)
        timelines[tIndex].layers.insert(layer, at: lIndex + 1)
        return layer.id
    }
}
