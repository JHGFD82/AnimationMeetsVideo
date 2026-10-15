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
    }

    var content: Content
    var stack: ClipStack
    /// The root times it draws in.
    var range: CMTimeRange
    /// The clip of the root timeline it belongs to, for naming the clips a
    /// rendered stretch takes part in.
    var owner: UUID
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
        guard case .group(var group) = content else { return self }
        group.children = group.children.compactMap { $0.pruned(to: range) }
        guard !group.children.isEmpty else { return nil }
        var copy = self
        copy.content = .group(group)
        return copy
    }

    /// Every picture drawn from a track in it, top first.
    var leaves: [(clip: DrawClip, media: MediaDraw)] {
        switch content {
        case .media(let media): [(self, media)]
        case .group(let group): group.children.flatMap(\.leaves)
        }
    }

    /// This clip and every clip inside it.
    var everyClip: [DrawClip] {
        switch content {
        case .media: [self]
        case .group(let group): [self] + group.children.flatMap(\.everyClip)
        }
    }

    /// The root times in which anything in it changes from frame to frame.
    var animatedRanges: [CMTimeRange] {
        everyClip.flatMap(\.stack.animatedRanges).merged()
    }

    var hasTransitions: Bool {
        everyClip.contains { $0.stack.hasTransitions }
    }
}
