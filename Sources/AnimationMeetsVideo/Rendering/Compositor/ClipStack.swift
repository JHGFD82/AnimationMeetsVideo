import CoreGraphics
import CoreMedia
import Foundation

/// A clip's stack and transitions as the compositor sees them: what to
/// draw at each moment, with the times its keyframes and transitions count
/// in. Built when the timeline is, so drawing needs nothing from the
/// project.
struct ClipStack: @unchecked Sendable {
    var effects: [Effect] = []
    var anchorPoint = AnimatedValue(Vector2.zero)
    /// Center of the frame of the timeline the clip is in, which is the
    /// center of its fitted picture.
    var center: CGPoint = .zero
    /// Root time minus the time of the timeline the clip is in.
    var shift: CMTime = .zero
    /// The clip's start in its timeline minus its trim start: its source
    /// time is its timeline's time minus this, and its keyframes count in
    /// source time.
    var sourceShift: CMTime = .zero
    /// The clip's transitions, in its timeline's time.
    var edges: EdgeTransitions?
    /// The color space of the timeline the clip is in, which Color steps
    /// convert from and back to.
    var colorSpace = ProjectColorSpace.rec709
    /// The clip, when it is retimed, which says where each moment of its
    /// timeline plays in its source. Otherwise `sourceShift` does.
    var retimed: TimelineClip?
    /// What the clip does with its finished picture across a frame, and how
    /// long a frame of its timeline lasts, which the shutter is part of.
    var shutter = ClipShutter()
    var frameDuration = CMTime.zero

    init(
        clip: TimelineClip, center: CGPoint, shift: CMTime, edges: EdgeTransitions? = nil,
        colorSpace: ProjectColorSpace = .rec709, frameDuration: CMTime = .zero
    ) {
        self.init(
            effects: clip.effects, anchorPoint: clip.anchorPoint, center: center, shift: shift,
            sourceShift: CMTimeSubtract(clip.startOffset, clip.trimStart), edges: edges, colorSpace: colorSpace
        )
        retimed = clip.isRetimed ? clip : nil
        shutter = clip.shutter
        self.frameDuration = frameDuration
    }

    init(
        effects: [Effect] = [], anchorPoint: AnimatedValue<Vector2> = AnimatedValue(.zero), center: CGPoint = .zero,
        shift: CMTime = .zero, sourceShift: CMTime = .zero, edges: EdgeTransitions? = nil,
        colorSpace: ProjectColorSpace = .rec709
    ) {
        self.colorSpace = colorSpace
        self.effects = effects
        self.anchorPoint = anchorPoint
        self.center = center
        self.shift = shift
        self.sourceShift = sourceShift
        self.edges = edges
    }

    /// A stack that does nothing, for a picture drawn as it is.
    static let none = ClipStack()

    /// The clip's time in its own timeline at root time `time`.
    func localTime(atRoot time: CMTime) -> CMTime {
        CMTimeSubtract(time, shift)
    }

    /// What the stack and transitions draw at root time `time`.
    func resolve(atRoot time: CMTime) -> ResolvedClip {
        let local = localTime(atRoot: time)
        return ResolvedClip(
            steps: StackFolding.steps(effects: effects, anchorPoint: anchorPoint, at: sourceTime(atLocal: local), center: center),
            transition: edges?.effect(at: local)
        )
    }

    /// The transition drawn from two whole pictures playing at root time
    /// `time`, if any (`TransitionRenderer`).
    func transitionFrame(atRoot time: CMTime) -> TransitionFrame? {
        edges?.transitionFrame(at: localTime(atRoot: time))
    }

    /// The clip's source time at `local` in its timeline.
    func sourceTime(atLocal local: CMTime) -> CMTime {
        retimed?.sourceTime(atTimelineTime: local) ?? CMTimeSubtract(local, sourceShift)
    }

    /// The timeline time a moment of the clip's source plays at.
    func timelineTime(forSource source: CMTime) -> CMTime {
        retimed?.timelineTime(forSourceTime: source) ?? CMTimeAdd(source, sourceShift)
    }

    var hasTransitions: Bool { edges != nil }

    /// Whether an effect in the stack gives a different picture when it is
    /// drawn at another size, such as a blur whose radius is in pixels.
    /// Position, Scale, Rotation, Opacity, Blending and Color work on single
    /// pixels, so none yet.
    var dependsOnPixelSize: Bool {
        effects.contains { $0.enabled && $0.kind.dependsOnPixelSize }
    }

    /// Root-time ranges where the stack or the transitions are changing, in
    /// order and not overlapping. Outside them the clip is drawn the same
    /// way at every moment.
    var animatedRanges: [CMTimeRange] {
        let keyframed = (effects.flatMap(\.animatedRanges) + [anchorPoint.animatedRange].compactMap { $0 }).map {
            // (A backwards clip plays its later footage first.)
            let a = timelineTime(forSource: $0.lowerBound), b = timelineTime(forSource: $0.upperBound)
            return CMTimeRange(
                start: CMTimeAdd(CMTimeMinimum(a, b), shift),
                end: CMTimeAdd(CMTimeMaximum(a, b), shift)
            )
        }
        let transitions = (edges?.animatedRanges ?? []).map {
            CMTimeRange(start: CMTimeAdd($0.start, shift), duration: $0.duration)
        }
        return (keyframed + transitions).merged()
    }

    /// Whether the stack changes the picture at any moment of `range`.
    func isNoOp(over range: CMTimeRange, frame: CMTime) -> Bool {
        if !resolve(atRoot: range.start).steps.isEmpty { return false }
        return !animatedRanges.contains { animated in
            let overlap = animated.intersection(range)
            return overlap.isValid && overlap.duration > .zero
        }
    }
}

extension Array where Element == CMTimeRange {
    /// Sorted, with ranges that touch or overlap joined.
    func merged() -> [CMTimeRange] {
        var merged: [CMTimeRange] = []
        for range in sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = CMTimeRange(start: last.start, end: CMTimeMaximum(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// A clip's stack and transitions at one moment, ready to draw.
struct ResolvedClip: Equatable {
    var steps: [ResolvedStep]
    /// What the clip's transitions do now; nil when it has none.
    var transition: EdgeTransitions.Effect?

    /// The product of the stack's placing steps, skipping the others: all a
    /// pass-through nested clip can apply.
    var placement: (matrix: CGAffineTransform, opacity: Double) {
        var matrix = CGAffineTransform.identity
        var opacity = 1.0
        for case .place(let m, let o) in steps {
            matrix = matrix.concatenating(m)
            opacity *= o
        }
        return (matrix, opacity)
    }

    /// Whether any step works on the picture's pixels, which costs more than
    /// moving it: blending and grading.
    var changesPixels: Bool {
        steps.contains {
            switch $0 {
            case .blend, .color, .matte, .shape: true
            case .place, .mark: false
            }
        }
    }
}
