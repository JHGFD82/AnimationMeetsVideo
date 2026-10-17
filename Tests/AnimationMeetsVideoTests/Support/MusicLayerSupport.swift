import CoreMedia
@testable import AnimationMeetsVideo

extension EditingProject {
    /// Puts a clip of each asset's sound on a new Music layer of the root
    /// timeline: only assets on music layers are analyzed for beats.
    mutating func putOnMusicLayer(_ assetIDs: [UUID]) {
        let clips = assetIDs.map { id in
            var clip = TimelineClip(
                source: .media(id), startOffset: .zero, trimStart: .zero,
                trimEnd: mediaClip(id: id)?.duration ?? CMTime(seconds: 1, preferredTimescale: 600)
            )
            clip.streams = .audio
            return clip
        }
        guard let index = timelines.firstIndex(where: { $0.id == rootTimelineID }) else { return }
        timelines[index].layers.append(TimelineLayer(customName: nil, kind: .music, clips: clips))
    }
}
