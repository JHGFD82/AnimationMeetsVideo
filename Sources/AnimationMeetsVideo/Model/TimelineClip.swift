import CoreMedia
import Foundation

enum ClipSource: Equatable {
    case media(UUID)
    case timeline(UUID)
    /// No picture of its own: its effect stack is applied to the layers
    /// below it. Only on an adjustment layer.
    case adjustment
    /// Starts from transparency, so its picture is what the shapes in its
    /// stack draw (see docs/graphic-layers.md).
    case graphic
}

/// A placement of a clip (raw media or a nested timeline) on a layer, with
/// its own non-destructive trim range and an independent, draggable
/// position in time — clips are not forced to be back-to-back or to start
/// at the timeline's t=0.
struct TimelineClip: Identifiable, Equatable {
    var id = UUID()
    var source: ClipSource
    var startOffset: CMTime
    var trimStart: CMTime
    var trimEnd: CMTime
    /// Non-destructive Vision-based foreground matte. Currently disabled in
    /// the UI pending a working live-preview capture pipeline; kept on the
    /// model since it's harmless and non-destructive by construction.
    var autoMatteEnabled: Bool = false
    /// Which of a media file's streams this clip plays. Always
    /// `.videoAndAudio` for nested timelines.
    var streams: ClipStreams = .videoAndAudio
    /// Brings the clip in at its start, and takes it out at its end.
    var transitionIn: ClipTransition?
    var transitionOut: ClipTransition?
    /// The point scale and rotation turn about: an offset from the center of
    /// the clip's fitted picture, in timeline pixels at 100% scale. Keyframed
    /// in the clip's source time, like everything on the clip. Clips with no
    /// pictures have none.
    var anchorPoint = AnimatedValue(Vector2.zero)
    /// What is done to the picture, top to bottom (see `Effect`).
    var effects: [Effect] = []
    /// What is done to the sound, top to bottom: effects whose kind
    /// `isAudio`, played before the clip's volume and pan.
    var audioEffects: [Effect] = []
    /// The volume of the clip's sound, in decibels (see `AudioLevel`),
    /// keyframed in the clip's source time. Clips with no sound have none.
    var volume = AnimatedValue(0.0)
    /// Where the clip's sound sits between the speakers (see `AudioPan`),
    /// keyframed in the clip's source time like its volume.
    var pan = AnimatedValue(0.0)
    /// For a nested timeline: draw its layers straight into the timeline
    /// it is placed in instead of as one picture (see docs/effects.md).
    var passThrough = false
    /// What the clip does to time (speed, frame blending, echo and sound),
    /// above its stack. See `ClipTime`.
    var time = ClipTime()
    /// What it does with its finished picture (motion blur and trails),
    /// below its transitions. See `ClipShutter`.
    var shutter = ClipShutter()
    /// For an adjustment clip: the lowest layer its effect reaches, stored
    /// as that layer's ID rather than a count so it stays put as layers are
    /// added and moved. Nil, or a layer not in its timeline, reaches every
    /// layer below.
    var reach: UUID?
    /// Off, the clip stays where it is on its layer but plays nothing: it
    /// is left out of the picture, the sound and exports, as a gap (V).
    var enabled = true
    /// Silences the clip's sound without taking it away: it stays linked,
    /// keeps its volume, and can be unmuted or detached later (detaching
    /// unmutes it). Placing video from the browser sets it when the
    /// browser is set to mute added sound.
    var soundMuted = false
    /// Where the clip is tied to a song on a Music layer, which it follows
    /// when the song moves; nil while no song is under it, and always on
    /// Music layers. See `followMusic(from:)`.
    var music: MusicAttachment?
    /// Off, the clip is never attached to the music and stays put when
    /// songs move.
    var followsMusic = true

    /// The length of the part of the source the clip plays. How long it lasts
    /// on the timeline is `placedDuration`, which differs when it is retimed.
    var trimmedDuration: CMTime {
        CMTimeSubtract(trimEnd, trimStart)
    }

    var endOffset: CMTime {
        CMTimeAdd(startOffset, placedDuration)
    }
}

extension [TimelineClip] {
    /// Splits at source time `time`. The second half starts at
    /// `startingSecondAt` in the timeline, or where that source time plays.
    mutating func splitClip(_ id: UUID, at time: CMTime, startingSecondAt secondStartTime: CMTime? = nil) {
        guard let index = firstIndex(id: id) else { return }
        let clip = self[index]
        guard time > clip.trimStart, time < clip.trimEnd else { return }
        // The split point is in source time; convert it to where that point
        // plays in the timeline, so the second half starts exactly where the
        // first half now ends — no gap introduced by splitting, even though
        // either half can be dragged apart afterward.
        let secondStart = secondStartTime ?? clip.timelineTime(forSourceTime: time)
        // Both halves get new IDs, so nothing goes on pointing at the whole
        // clip as if it were one of them. A song's followers find their
        // piece again by time (see `MusicAttachment.songClipID`).
        //
        // The first half keeps the way in, the second the way out.
        // (A backwards clip plays the later footage first.)
        var first = clip
        first.id = UUID()
        if clip.isReversed { first.trimStart = time } else { first.trimEnd = time }
        first.transitionOut = nil
        var second = clip
        second.id = UUID()
        second.startOffset = secondStart
        if clip.isReversed { second.trimEnd = time } else { second.trimStart = time }
        second.transitionIn = nil
        replaceSubrange(index...index, with: [first, second])
    }
}

/// Which streams of a media file a clip plays. A video with sound plays
/// both, linked, until its audio is detached: then the picture stays as a
/// `.video` clip and the sound moves to an `.audio` clip on its own layer.
enum ClipStreams: String {
    case videoAndAudio
    case video
    case audio
}
