import CoreGraphics
import CoreMedia
import Foundation

/// A timeline as the compositor draws it: layers' clips from the top down,
/// where a nested timeline is a group holding the clips of its own layers
/// (see docs/effects.md, "How a clip is drawn"). Built with the
/// composition and not changed afterwards, so frames can be drawn from any
/// thread.
struct DrawClip: @unchecked Sendable {
    enum Content: @unchecked Sendable {
        case media(MediaDraw)
        case group(GroupDraw)
        case adjustment(AdjustmentDraw)
    }

    var content: Content
    var stack: ClipStack
    /// The root times it draws in.
    var range: CMTimeRange
    /// The clip of the root timeline it belongs to, for naming the clips a
    /// rendered stretch takes part in.
    var owner: UUID
    /// The layer of its timeline it is on, which an adjustment layer's
    /// reach is made of.
    var layerID = UUID()
}

/// An adjustment clip: no picture of its own, but a stack applied to the
/// layers it reaches (see docs/effects.md, "Adjustment layers").
struct AdjustmentDraw: @unchecked Sendable {
    /// The layers below it, in its timeline, that it reaches: all of them
    /// down to its reach, or none when the layer it reaches down to is above
    /// it.
    var reachedLayerIDs: Set<UUID>
    /// Whether it reaches every layer below it, whichever they are.
    var reachesAll: Bool
    /// The clips of those layers drawn while it plays, top first. Filled in
    /// by `DrawClip.assembled` as the tree is cut down to a stretch.
    var reached: [DrawClip] = []
}

/// Another composition track holding the same footage, put earlier or later
/// than the clip's own: the frame after the current one for frame blending,
/// or earlier frames for echo and trails.
struct TrackCopy: Equatable, Sendable {
    var trackID: CMPersistentTrackID
    /// The root times it has frames for.
    var range: CMTimeRange
    /// How strong it is next to the clip's own picture.
    var strength: Double
    /// How much later in time its footage plays than the clip's own, so a
    /// moment of it is how the clip was that long before.
    var delay = CMTime.zero
}

/// A picture read from a composition track.
struct MediaDraw: @unchecked Sendable {
    var trackID: CMPersistentTrackID
    /// Orients the track's frames and fits them into the frame of the
    /// timeline the clip is in (pixels, origin top left).
    var base: CGAffineTransform
    var url: URL
    /// The file time drawn at `segmentStart`.
    var sourceStart: CMTime
    /// The root time `sourceStart` plays at.
    var segmentStart: CMTime
    /// How long a frame of the file lasts, and how much later a moment is in
    /// the file than in the original, for finding where between two frames
    /// a retimed moment falls.
    var frameDuration = CMTime.zero
    var alignmentOffset = CMTime.zero
    /// For Blend: the footage a frame later, to mix with the current frame
    /// by how far between the two the moment is.
    var nextFrame: TrackCopy?
    /// For Echo: earlier frames, nearest first, layered under the current one.
    var echoes: [TrackCopy] = []
    /// For Trails: the footage as it was at earlier moments, nearest first,
    /// for copies of the finished clip.
    var trails: [TrackCopy] = []

    /// Every track the picture may be read from.
    var trackIDs: [CMPersistentTrackID] {
        [trackID] + [nextFrame].compactMap { $0 }.map(\.trackID) + echoes.map(\.trackID) + trails.map(\.trackID)
    }

    /// The same, keeping only the copies that have frames throughout `range`.
    func covering(_ range: CMTimeRange) -> MediaDraw {
        var copy = self
        func covers(_ copy: TrackCopy) -> Bool { copy.range.start <= range.start && copy.range.end >= range.end }
        copy.nextFrame = nextFrame.flatMap { covers($0) ? $0 : nil }
        copy.echoes = echoes.filter(covers)
        copy.trails = trails.filter(covers)
        return copy
    }
}

/// A nested timeline.
struct GroupDraw: @unchecked Sendable {
    /// The nested timeline's frame.
    var frameSize: CGSize
    /// Fits its frame into the frame of the timeline it is placed in.
    var toOuter: CGAffineTransform
    /// Whether its layers are drawn straight into that timeline instead of
    /// as one picture.
    var passThrough: Bool
    /// Its layers' clips, top first.
    var children: [DrawClip]
    /// Whether the group's move may be applied to each layer inside, which
    /// is the same picture only while every step inside works on single
    /// pixels. An effect that depends on pixel size stops it.
    var pushesTransforms = true
}

extension DrawClip {
    /// The clip as drawn throughout `range`, which must not straddle the
    /// start or end of anything in it: nil if it isn't drawn there, with
    /// groups cut down to the children that are.
    func pruned(to range: CMTimeRange) -> DrawClip? {
        guard self.range.start <= range.start, self.range.end >= range.end else { return nil }
        if case .media(let media) = content {
            var copy = self
            copy.content = .media(media.covering(range))
            return copy
        }
        guard case .group(var group) = content else { return self }
        group.children = Self.assembled(group.children.compactMap { $0.pruned(to: range) })
        guard !group.children.isEmpty else { return nil }
        var copy = self
        copy.content = .group(group)
        return copy
    }

    /// The clips of one timeline (top first), cut down to a stretch, with
    /// each adjustment clip taking the clips of the layers it reaches. Those
    /// are drawn through it instead of on their own. Lower adjustments go
    /// first, so one reaching down to them gets them as they are adjusted.
    static func assembled(_ clips: [DrawClip]) -> [DrawClip] {
        var below: [DrawClip] = []
        for clip in clips.reversed() {
            guard case .adjustment(var adjustment) = clip.content else {
                below.insert(clip, at: 0)
                continue
            }
            let reaches: (DrawClip) -> Bool = { adjustment.reachesAll || adjustment.reachedLayerIDs.contains($0.layerID) }
            adjustment.reached = below.filter(reaches)
            below.removeAll(where: reaches)
            var taken = clip
            taken.content = .adjustment(adjustment)
            below.insert(taken, at: 0)
        }
        return below
    }

    /// Every picture drawn from a track in it, top first.
    var leaves: [(clip: DrawClip, media: MediaDraw)] {
        switch content {
        case .media(let media): [(self, media)]
        case .group(let group): group.children.flatMap(\.leaves)
        case .adjustment(let adjustment): adjustment.reached.flatMap(\.leaves)
        }
    }

    /// This clip and every clip inside it.
    var everyClip: [DrawClip] {
        switch content {
        case .media: [self]
        case .group(let group): [self] + group.children.flatMap(\.everyClip)
        case .adjustment(let adjustment): [self] + adjustment.reached.flatMap(\.everyClip)
        }
    }

    /// Whether it is an adjustment clip.
    var isAdjustment: Bool {
        if case .adjustment = content { true } else { false }
    }

    /// The root times in which anything in it changes from frame to frame.
    var animatedRanges: [CMTimeRange] {
        everyClip.flatMap(\.stack.animatedRanges).merged()
    }

    var hasTransitions: Bool {
        everyClip.contains { $0.stack.hasTransitions }
    }
}
