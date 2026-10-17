import CoreMedia
import Foundation

// The beat markers a timeline layer shows, and which layers have any.
extension EditingProject {
    /// Where the beats of one timeline layer fall in timeline time: each clip
    /// on the layer contributes the beats inside its trimmed range, moved to
    /// where the clip sits. Empty for layers with no audio beats.
    ///
    /// A song the person has beat matched gives its confirmed beats, with
    /// their places in the measure; any other gives its detected beats.
    /// Detected beats are found in the current file, but trims are in the
    /// original's time, so a replaced file's alignment offset is applied in
    /// between; confirmed beats are in original time already.
    func beatMarkers(in layer: TimelineLayer, tracks: [UUID: BeatTrack]) -> [BeatMarker] {
        var markers: [BeatMarker] = []
        for clip in layer.clips {
            if let map = confirmedMap(of: clip) {
                for beat in map.confirmedBeats where Self.isInTrim(beat.time, of: clip) {
                    markers.append(BeatMarker(time: clip.timelineTime(forSourceTime: beat.time), position: beat.position))
                }
                continue
            }
            guard let played = playedBeats(of: clip, tracks: tracks) else { continue }
            for beat in played.track.beats(from: played.fileStart, to: played.fileEnd) {
                // A retimed clip plays the file faster or slower, so a beat
                // lands where the footage under it does.
                let source = CMTimeAdd(clip.trimStart, CMTimeSubtract(beat, played.fileStart))
                markers.append(BeatMarker(time: clip.timelineTime(forSourceTime: source)))
            }
        }
        return markers.sorted { CMTimeCompare($0.time, $1.time) < 0 }
    }

    /// The beat map a clip plays, when the person has confirmed beats in it.
    private func confirmedMap(of clip: TimelineClip) -> BeatMap? {
        guard case .media(let assetID) = clip.source, let asset = mediaClip(id: assetID),
              asset.beatMap.hasConfirmedBeats, playsAudio(clip)
        else { return nil }
        return asset.beatMap
    }

    /// The same half-open trim range the detected beats are taken from.
    private static func isInTrim(_ time: CMTime, of clip: TimelineClip) -> Bool {
        CMTimeCompare(time, clip.trimStart) >= 0 && CMTimeCompare(time, clip.trimEnd) < 0
    }

    /// The layers of a timeline whose audio has beats, for the beat marker
    /// picker. A layer drops out as soon as it is deleted or its clips lose
    /// their beats, so nothing needs cleaning up.
    func beatLayers(in timeline: Timeline, tracks: [UUID: BeatTrack]) -> [TimelineLayer] {
        timeline.layers.filter { layerHasBeats($0, tracks: tracks) }
    }

    /// True when `beatMarkers(in:tracks:)` would give the layer at least one
    /// marker: some clip plays audio with a beat inside its trimmed range.
    func layerHasBeats(_ layer: TimelineLayer, tracks: [UUID: BeatTrack]) -> Bool {
        layer.clips.contains { clip in
            if let map = confirmedMap(of: clip) {
                return map.confirmedBeats.contains { Self.isInTrim($0.time, of: clip) }
            }
            guard let played = playedBeats(of: clip, tracks: tracks) else { return false }
            return played.track.hasBeats(from: played.fileStart, to: played.fileEnd)
        }
    }

    /// The beat track a clip plays and its trimmed range in the track's
    /// file time, or nil when the clip plays no audio with detected beats.
    /// Shared by the markers and the picker so they never disagree.
    private func playedBeats(
        of clip: TimelineClip, tracks: [UUID: BeatTrack]
    ) -> (track: BeatTrack, fileStart: CMTime, fileEnd: CMTime)? {
        guard case .media(let assetID) = clip.source, let track = tracks[assetID],
              let asset = mediaClip(id: assetID), playsAudio(clip)
        else { return nil }
        return (track, asset.fileTime(forSourceTime: clip.trimStart), asset.fileTime(forSourceTime: clip.trimEnd))
    }
}
