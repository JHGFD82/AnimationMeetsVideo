import CoreMedia
import Foundation

// Clips attached to the music: footage follows the song it was cut to, so
// moving the song moves the footage with it (see docs/motion-designer.md,
// "Clips attached to the music").

/// Where a clip is tied to a song: one of the clip's frames, and the moment
/// of the song it plays on.
struct MusicAttachment: Equatable {
    /// The song's clip on a Music layer of the same timeline. Cutting the
    /// song gives its pieces new IDs, so this is where to look first; the
    /// piece of the same asset holding `songTime` is the fallback.
    var songClipID: UUID
    var assetID: UUID
    /// The moment of the song, in the song clip's source time.
    var songTime: CMTime
    /// The frame of the clip, in its source time, that plays at `songTime`,
    /// when the person chose one; nil for the clip's first frame.
    var frame: CMTime?
}

extension TimelineClip {
    /// The frame that ties the clip to the music: `chosen` while the clip
    /// still plays it, else the first frame it plays (the end of its trim
    /// when it plays backwards).
    func musicFrame(_ chosen: CMTime?) -> CMTime {
        if let chosen, chosen >= trimStart, chosen <= trimEnd { return chosen }
        return isReversed ? trimEnd : trimStart
    }

    /// Whether the clip sits differently than `other`: moved, trimmed,
    /// slipped or retimed.
    func isPlacedDifferently(than other: TimelineClip) -> Bool {
        startOffset != other.startOffset || trimStart != other.trimStart || trimEnd != other.trimEnd
            || time.speed != other.time.speed
    }
}

extension Timeline {
    /// The song playing at `time`: the clip there on the first Music layer
    /// that has one, else the second, and so on.
    func song(at time: CMTime) -> TimelineClip? {
        for layer in layers where layer.kind == .music {
            if let clip = layer.clips.first(where: { $0.startOffset <= time && time < $0.endOffset }), case .media = clip.source {
                return clip
            }
        }
        return nil
    }

    /// The song clip with this ID on a Music layer.
    func songClip(id: UUID) -> TimelineClip? {
        for layer in layers where layer.kind == .music {
            if let clip = layer.clips.first(id: id) { return clip }
        }
        return nil
    }

    /// The song an attachment follows: its clip, else the piece of the same
    /// asset holding its moment, the one nearest `time` if the song is
    /// placed more than once. Nil once the song is gone.
    func song(following attachment: MusicAttachment, near time: CMTime) -> TimelineClip? {
        if let clip = songClip(id: attachment.songClipID) { return clip }
        let pieces = layers.filter { $0.kind == .music }.flatMap(\.clips).filter { clip in
            clip.source == .media(attachment.assetID) && clip.trimStart <= attachment.songTime && attachment.songTime <= clip.trimEnd
        }
        return pieces.min { a, b in
            let toA = CMTimeAbsoluteValue(CMTimeSubtract(a.timelineTime(forSourceTime: attachment.songTime), time))
            let toB = CMTimeAbsoluteValue(CMTimeSubtract(b.timelineTime(forSourceTime: attachment.songTime), time))
            return toA < toB
        }
    }

    /// Ties `clip` to the song under its frame `chosen` (its first frame
    /// for nil), or nil when no song plays there.
    func musicAttachment(for clip: TimelineClip, frame chosen: CMTime?) -> MusicAttachment? {
        let frame = clip.musicFrame(chosen)
        let time = clip.timelineTime(forSourceTime: frame)
        guard let song = song(at: time), case .media(let assetID) = song.source else { return nil }
        return MusicAttachment(
            songClipID: song.id, assetID: assetID, songTime: song.sourceTime(atTimelineTime: time),
            frame: chosen == frame ? chosen : nil
        )
    }
}

extension EditingProject {
    /// Brings the clips attached to the music along after an edit, judged
    /// against the project as it was just before (`old`). On every layer but
    /// Music layers:
    ///
    /// - A clip whose song moved, and which didn't move itself, moves to
    ///   play its frame on the song's moment again. Footage in its way on
    ///   its layer is pushed later.
    /// - A clip that is new, or moved, trimmed, slipped or retimed itself,
    ///   is attached again where it now sits, as is footage pushed aside.
    /// - A clip with no song under it waits unattached until one is put
    ///   there; one set not to follow the music never attaches.
    ///
    /// Returns whether anything changed. Run it after edits only, not after
    /// undo, whose snapshots are already as they should be.
    @discardableResult
    mutating func followMusic(from old: EditingProject) -> Bool {
        var changed = false
        for t in timelines.indices {
            let followed = followingMusic(timelines[t], from: old.timeline(id: timelines[t].id))
            if followed != timelines[t] {
                timelines[t] = followed
                changed = true
            }
        }
        return changed
    }

    private func followingMusic(_ timeline: Timeline, from old: Timeline?) -> Timeline {
        var result = timeline
        var previous: [UUID: TimelineClip] = [:]
        for layer in old?.layers ?? [] where layer.kind != .music {
            for clip in layer.clips { previous[clip.id] = clip }
        }

        for l in result.layers.indices where result.layers[l].kind != .music {
            var followers: Set<UUID> = []
            for c in result.layers[l].clips.indices {
                var clip = result.layers[l].clips[c]
                defer { result.layers[l].clips[c] = clip }
                guard clip.followsMusic else {
                    clip.music = nil
                    continue
                }
                guard let before = previous[clip.id], !clip.isPlacedDifferently(than: before), let attachment = clip.music,
                      let song = timeline.song(following: attachment, near: clip.startOffset)
                else {
                    clip.music = timeline.musicAttachment(for: clip, frame: clip.music?.frame)
                    continue
                }
                clip.music?.songClipID = song.id
                let now = song.timelineTime(forSourceTime: attachment.songTime)
                guard let was = old?.songClip(id: attachment.songClipID)?.timelineTime(forSourceTime: attachment.songTime),
                      was != now
                else { continue }
                let frameAt = clip.timelineTime(forSourceTime: clip.musicFrame(attachment.frame))
                let start = CMTimeMaximum(.zero, CMTimeAdd(clip.startOffset, CMTimeSubtract(now, frameAt)))
                clip.startOffset = timeline.placementTime(start, .nearest, frameLocked: isFrameLocked(clip))
                followers.insert(clip.id)
            }
            if !followers.isEmpty {
                result.layers[l].clips = makingRoom(for: followers, among: result.layers[l].clips, in: result)
            }
        }
        return result
    }

    /// The clips of a layer with those that followed their songs kept where
    /// they are, and the rest pushed later, in order, past any they would
    /// overlap. Pushed clips are attached again where they land.
    private func makingRoom(for followers: Set<UUID>, among clips: [TimelineClip], in timeline: Timeline) -> [TimelineClip] {
        var placed = clips.filter { followers.contains($0.id) }
        for var clip in clips.filter({ !followers.contains($0.id) }).sorted(by: { $0.startOffset < $1.startOffset }) {
            let start = clip.startOffset
            while let blocker = placed.first(where: { clip.startOffset < $0.endOffset && $0.startOffset < clip.endOffset }) {
                clip.startOffset = timeline.placementTime(blocker.endOffset, .up, frameLocked: isFrameLocked(clip))
            }
            if clip.startOffset != start, clip.followsMusic {
                clip.music = timeline.musicAttachment(for: clip, frame: clip.music?.frame)
            }
            placed.append(clip)
        }
        return placed.sorted { $0.startOffset < $1.startOffset }
    }

    /// Ties a clip to the music at a time inside it, such as the playhead:
    /// the frame playing there plays on the song's moment there. It follows
    /// the music from then on, if it didn't. Nothing happens outside the clip.
    mutating func attachToMusic(_ clipID: UUID, in timelineID: UUID, at time: CMTime) {
        guard let timeline = timeline(id: timelineID),
              let clip = timeline.layers.flatMap(\.clips).first(id: clipID),
              clip.startOffset <= time, time <= clip.endOffset
        else { return }
        let frame = clip.sourceTime(atTimelineTime: time)
        editClip(clipID, in: timelineID) {
            $0.followsMusic = true
            $0.music = timeline.musicAttachment(for: clip, frame: frame)
        }
    }
}

extension Timeline {
    /// The stretches of a Music layer's clip where it is the song (see
    /// `song(at:)`): all of it but where a clip on a Music layer above
    /// plays.
    func songStretches(of clip: TimelineClip, onLayer layerID: UUID) -> [CMTimeRange] {
        var stretches = [CMTimeRange(start: clip.startOffset, end: clip.endOffset)]
        for layer in layers where layer.kind == .music {
            if layer.id == layerID { break }
            for above in layer.clips {
                guard case .media = above.source else { continue }
                let cut = CMTimeRange(start: above.startOffset, end: above.endOffset)
                stretches = stretches.flatMap { stretch -> [CMTimeRange] in
                    guard cut.start < stretch.end, stretch.start < cut.end else { return [stretch] }
                    var left: [CMTimeRange] = []
                    if stretch.start < cut.start { left.append(CMTimeRange(start: stretch.start, end: cut.start)) }
                    if cut.end < stretch.end { left.append(CMTimeRange(start: cut.end, end: stretch.end)) }
                    return left
                }
            }
        }
        return stretches
    }
}

extension EditingProject {
    /// The beats of the music a timeline's footage is cut to: at each
    /// moment, those of the song playing then (`Timeline.song(at:)`), so a
    /// song on a lower Music layer counts only where none above plays.
    func musicBeats(in timeline: Timeline, tracks: [UUID: BeatTrack]) -> [BeatMarker] {
        var beats: [BeatMarker] = []
        for layer in timeline.layers where layer.kind == .music {
            let songs = Set(layer.clips.map(\.id))
            for beat in beatMarkers(in: layer, tracks: tracks) {
                if let song = timeline.song(at: beat.time), songs.contains(song.id) { beats.append(beat) }
            }
        }
        return beats.sorted { CMTimeCompare($0.time, $1.time) < 0 }
    }
}
