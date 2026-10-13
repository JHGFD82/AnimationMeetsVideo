import CoreGraphics
import CoreMedia
import Foundation

/// The kinds of transition the transitions panel offers. Each one brings a
/// clip in at its leading edge or takes it out at its trailing edge, over
/// whatever is showing underneath it: lower layers, or the outgoing clip's
/// extra frames when two clips on the same layer meet at a cut.
///
/// Every kind is drawn with the built-in compositor's opacity, transform
/// and crop, so the preview and the export match exactly.
enum TransitionKind: String, CaseIterable, Identifiable {
    case crossDissolve
    case wipeLeft
    case wipeRight
    case wipeUp
    case wipeDown
    case slideLeft
    case slideRight
    case zoom

    var id: Self { self }

    var name: String {
        switch self {
        case .crossDissolve: "Cross Dissolve"
        case .wipeLeft: "Wipe Left"
        case .wipeRight: "Wipe Right"
        case .wipeUp: "Wipe Up"
        case .wipeDown: "Wipe Down"
        case .slideLeft: "Slide Left"
        case .slideRight: "Slide Right"
        case .zoom: "Zoom"
        }
    }

    /// The curve a newly dropped transition gets. Moves start and stop
    /// gently; fades and wipes run evenly.
    var defaultCurve: TransitionCurve {
        switch self {
        case .slideLeft, .slideRight, .zoom: TransitionCurve(preset: .easyEase)
        default: .linear
        }
    }

    var systemImage: String {
        switch self {
        case .crossDissolve: "circle.lefthalf.filled"
        case .wipeLeft: "arrow.left.to.line"
        case .wipeRight: "arrow.right.to.line"
        case .wipeUp: "arrow.up.to.line"
        case .wipeDown: "arrow.down.to.line"
        case .slideLeft: "rectangle.lefthalf.inset.filled.arrow.left"
        case .slideRight: "rectangle.righthalf.inset.filled.arrow.right"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// Which end of a clip a transition sits on.
enum TransitionEdge: Hashable {
    case leading, trailing
}

struct ClipTransition: Equatable {
    var kind: TransitionKind
    var duration: CMTime
    /// How it progresses over its length.
    var curve: TransitionCurve = .linear

    /// What a transition is given when it is first dropped on a clip.
    static let defaultDuration = CMTime(value: 1, timescale: 1)
}

extension TimelineClip {
    func transition(at edge: TransitionEdge) -> ClipTransition? {
        switch edge {
        case .leading: transitionIn
        case .trailing: transitionOut
        }
    }

    mutating func setTransition(_ transition: ClipTransition?, at edge: TransitionEdge) {
        switch edge {
        case .leading: transitionIn = transition
        case .trailing: transitionOut = transition
        }
    }

    /// The lengths the transitions actually play for. A trim can leave the
    /// stored lengths longer than the clip; then they share the clip in
    /// proportion, so the two never overlap.
    var effectiveTransitionDurations: (leading: CMTime, trailing: CMTime) {
        let total = trimmedDuration
        let leading = transitionIn.map { CMTimeMinimum($0.duration, total) } ?? .zero
        let trailing = transitionOut.map { CMTimeMinimum($0.duration, total) } ?? .zero
        let sum = CMTimeAdd(leading, trailing)
        guard sum > total, sum.seconds > 0 else { return (leading, trailing) }
        let share = total.seconds / sum.seconds
        return (
            CMTimeMultiplyByFloat64(leading, multiplier: share),
            CMTimeMultiplyByFloat64(trailing, multiplier: share)
        )
    }
}

// MARK: - Editing

extension EditingProject {
    /// Puts a transition on one end of a clip. One already there keeps its
    /// length and curve and only changes kind; a new one is a second long,
    /// or shorter to fit beside the transition at the other end, with its
    /// kind's default curve. Only clips with pictures take transitions.
    mutating func setTransition(_ kind: TransitionKind, at edge: TransitionEdge, of clipID: UUID, in timelineID: UUID, layer layerID: UUID) {
        guard let timeline = timeline(id: timelineID),
              let clip = timeline.layer(id: layerID)?.clips.first(where: { $0.id == clipID }),
              playsVideo(clip)
        else {
            return
        }
        let duration: CMTime
        var curve = kind.defaultCurve
        if let existing = clip.transition(at: edge) {
            duration = existing.duration
            curve = existing.curve
        } else {
            let other = clip.transition(at: edge == .leading ? .trailing : .leading)?.duration ?? .zero
            let room = CMTimeSubtract(clip.trimmedDuration, other)
            let fitted = timeline.frameAligned(CMTimeMinimum(ClipTransition.defaultDuration, room), .down)
            duration = fitted > .zero ? fitted : timeline.frameDuration
        }
        updateClip(clipID, in: timelineID, layer: layerID) {
            $0.setTransition(ClipTransition(kind: kind, duration: duration, curve: curve), at: edge)
        }
    }

    /// Sets a transition's length, on the timeline's frames and no longer
    /// than the clip leaves beside the other end's transition.
    mutating func setTransitionDuration(_ duration: CMTime, at edge: TransitionEdge, of clipID: UUID, in timelineID: UUID, layer layerID: UUID) {
        guard let timeline = timeline(id: timelineID),
              let clip = timeline.layer(id: layerID)?.clips.first(where: { $0.id == clipID }),
              var transition = clip.transition(at: edge)
        else {
            return
        }
        let other = clip.transition(at: edge == .leading ? .trailing : .leading)?.duration ?? .zero
        let room = CMTimeMaximum(timeline.frameDuration, CMTimeSubtract(clip.trimmedDuration, other))
        let snapped = timeline.frameAligned(CMTimeMinimum(duration, room), .nearest)
        transition.duration = CMTimeMaximum(timeline.frameDuration, snapped)
        updateClip(clipID, in: timelineID, layer: layerID) { $0.setTransition(transition, at: edge) }
    }

    mutating func setTransitionCurve(_ curve: TransitionCurve, at edge: TransitionEdge, of clipID: UUID, in timelineID: UUID, layer layerID: UUID) {
        updateClip(clipID, in: timelineID, layer: layerID) { clip in
            guard var transition = clip.transition(at: edge) else { return }
            transition.curve = curve
            clip.setTransition(transition, at: edge)
        }
    }

    mutating func removeTransition(at edge: TransitionEdge, of clipID: UUID, in timelineID: UUID, layer layerID: UUID) {
        updateClip(clipID, in: timelineID, layer: layerID) { $0.setTransition(nil, at: edge) }
    }

    private mutating func updateClip(_ clipID: UUID, in timelineID: UUID, layer layerID: UUID, _ change: (inout TimelineClip) -> Void) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(where: { $0.id == clipID })
        else {
            return
        }
        change(&timelines[tIndex].layers[lIndex].clips[cIndex])
    }
}

// MARK: - Rendering

/// A clip's transitions placed in the time of the timeline it is on, for
/// rendering.
struct EdgeTransitions {
    var start: CMTime
    var end: CMTime
    var leading: (kind: TransitionKind, duration: CMTime, curve: TransitionCurve)?
    var trailing: (kind: TransitionKind, duration: CMTime, curve: TransitionCurve)?
    /// The frame of the timeline the clip is on.
    var frameSize: CGSize

    init?(clip: TimelineClip, frameSize: CGSize) {
        let durations = clip.effectiveTransitionDurations
        if let transition = clip.transitionIn, durations.leading > .zero {
            leading = (transition.kind, durations.leading, transition.curve)
        }
        if let transition = clip.transitionOut, durations.trailing > .zero {
            trailing = (transition.kind, durations.trailing, transition.curve)
        }
        guard leading != nil || trailing != nil else { return nil }
        start = clip.startOffset
        end = clip.endOffset
        self.frameSize = frameSize
    }

    /// What the transitions do to the clip at `time`, in its timeline's
    /// frame: how opaque it is, how it is moved, and the part of the frame
    /// it may show (nil when it isn't wiped).
    struct Effect {
        var opacity: Double = 1
        var transform: CGAffineTransform = .identity
        var visibleRect: CGRect?
    }

    var hasWipe: Bool {
        [leading?.kind, trailing?.kind].contains { $0?.isWipe == true }
    }

    /// Each transition's curve maps the fraction of its length that has
    /// passed to how far it has got; a way in shows more of the clip as it
    /// goes, a way out less.
    func effect(at time: CMTime) -> Effect {
        var effect = Effect()
        if let leading {
            let elapsed = CMTimeSubtract(time, start).seconds / leading.duration.seconds
            if elapsed < 1 {
                apply(leading.kind, visibility: leading.curve.value(at: elapsed), edge: .leading, to: &effect)
            }
        }
        if let trailing {
            let elapsed = 1 - CMTimeSubtract(end, time).seconds / trailing.duration.seconds
            if elapsed > 0 {
                apply(trailing.kind, visibility: 1 - trailing.curve.value(at: elapsed), edge: .trailing, to: &effect)
            }
        }
        if hasWipe, effect.visibleRect == nil {
            effect.visibleRect = CGRect(origin: .zero, size: frameSize)
        }
        return effect
    }

    /// The times the transitions are changing, in the clip's timeline.
    var animatedRanges: [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        if let leading { ranges.append(CMTimeRange(start: start, duration: leading.duration)) }
        if let trailing { ranges.append(CMTimeRange(start: CMTimeSubtract(end, trailing.duration), end: end)) }
        return ranges
    }

    /// `visibility` runs from 0 (the clip is not shown) to 1 (fully shown).
    /// A transition at the leading edge plays it upward, one at the trailing
    /// edge downward, so the motion keeps its direction: a slide to the right
    /// comes in from the left and leaves to the right.
    private func apply(_ kind: TransitionKind, visibility: Double, edge: TransitionEdge, to effect: inout Effect) {
        let v = min(max(visibility, 0), 1)
        let width = frameSize.width, height = frameSize.height
        let entering = edge == .leading
        switch kind {
        case .crossDissolve:
            effect.opacity *= v
        case .wipeLeft, .wipeRight, .wipeUp, .wipeDown:
            // The wipe's edge moves in the named direction both ways: it
            // uncovers the clip as it comes in and covers it as it leaves.
            let forward = kind == .wipeRight || kind == .wipeDown
            let shownFromStart = entering == forward
            var rect = CGRect(origin: .zero, size: frameSize)
            if kind == .wipeLeft || kind == .wipeRight {
                rect.size.width = width * v
                if !shownFromStart { rect.origin.x = width * (1 - v) }
            } else {
                rect.size.height = height * v
                if !shownFromStart { rect.origin.y = height * (1 - v) }
            }
            effect.visibleRect = effect.visibleRect.map { $0.intersection(rect) } ?? rect
        case .slideLeft, .slideRight:
            let direction: CGFloat = kind == .slideRight ? 1 : -1
            let distance = width * (1 - v) * direction
            effect.transform = effect.transform.concatenating(
                CGAffineTransform(translationX: entering ? -distance : distance, y: 0)
            )
        case .zoom:
            let scale = max(v, 0.001)
            effect.transform = effect.transform.concatenating(
                CGAffineTransform(translationX: -width / 2, y: -height / 2)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: width / 2, y: height / 2))
            )
            effect.opacity *= v
        }
    }
}

private extension TransitionKind {
    var isWipe: Bool {
        switch self {
        case .wipeLeft, .wipeRight, .wipeUp, .wipeDown: true
        default: false
        }
    }
}
