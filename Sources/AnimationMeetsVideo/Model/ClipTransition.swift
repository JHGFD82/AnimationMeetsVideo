import CoreGraphics
import CoreMedia
import Foundation

/// The kinds of transition the transitions panel offers. Each one brings a
/// clip in at its leading edge or takes it out at its trailing edge, over
/// whatever is showing underneath it: lower layers, or the outgoing clip's
/// extra frames when two clips on the same layer meet at a cut.
///
/// Every kind but the film dissolve is drawn with the built-in compositor's
/// opacity, transform and crop. The film dissolve keys on brightness, which
/// that compositor can't do, so a timeline using one is drawn by
/// `LayeredCompositor` instead, as is one where a nested timeline fades
/// over layers of its own that overlap. Preview and export use the same
/// path, so they match.
enum TransitionKind: String, CaseIterable, Identifiable {
    case crossDissolve
    case filmDissolve
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
        case .filmDissolve: "Film Dissolve"
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
        case .filmDissolve: "sun.max"
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
    /// For a way in that joins the clip to the one before it: how much of
    /// `duration` plays before the cut, over the end of that clip. Ignored
    /// when the clip joins none.
    var lead: CMTime = .zero

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

    /// The lengths the transitions play for inside the clip. `lead` is the
    /// part of the way in played before the clip's start, when it joins
    /// the clip before. A trim can leave the stored lengths longer than the
    /// clip; then they share it in proportion, so the two never overlap.
    func effectiveTransitionDurations(lead: CMTime = .zero) -> (leading: CMTime, trailing: CMTime) {
        let total = trimmedDuration
        let leading = transitionIn.map { CMTimeMinimum(CMTimeMaximum(.zero, CMTimeSubtract($0.duration, lead)), total) } ?? .zero
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
    ///
    /// Dropped where two clips on a layer meet, it joins them: it becomes
    /// the incoming clip's way in, centered on the cut as far as the spare
    /// footage beyond the two trims allows (see `fittedJoint`). Without
    /// spare footage it stays inside the incoming clip.
    mutating func setTransition(_ kind: TransitionKind, at edge: TransitionEdge, of clipID: UUID, in timelineID: UUID, layer layerID: UUID) {
        guard let timeline = timeline(id: timelineID),
              let layer = timeline.layer(id: layerID),
              var clip = layer.clips.first(where: { $0.id == clipID }),
              playsVideo(clip)
        else {
            return
        }
        var edge = edge
        if edge == .trailing, let next = successor(joining: clip, among: layer.clips) {
            clip = next
            edge = .leading
        }
        let existing = clip.transition(at: edge)
        let curve = existing?.curve ?? kind.defaultCurve

        if edge == .leading, let previous = predecessor(joining: clip, among: layer.clips) {
            let duration = existing?.duration ?? ClipTransition.defaultDuration
            let lead = existing.map(\.lead) ?? CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2)
            if let fit = fittedJoint(duration: duration, lead: lead, outgoing: previous, incoming: clip, in: timeline) {
                let transition = ClipTransition(kind: kind, duration: fit.duration, curve: curve, lead: fit.lead)
                updateClip(clip.id, in: timelineID, layer: layerID) { $0.setTransition(transition, at: .leading) }
                return
            }
        }

        let duration: CMTime
        if let existing {
            duration = existing.duration
        } else {
            let other = clip.transition(at: edge == .leading ? .trailing : .leading)?.duration ?? .zero
            let room = CMTimeSubtract(clip.trimmedDuration, other)
            let fitted = timeline.frameAligned(CMTimeMinimum(ClipTransition.defaultDuration, room), .down)
            duration = fitted > .zero ? fitted : timeline.frameDuration
        }
        updateClip(clip.id, in: timelineID, layer: layerID) {
            $0.setTransition(ClipTransition(kind: kind, duration: duration, curve: curve), at: edge)
        }
    }

    /// Sets a transition's length, on the timeline's frames and no longer
    /// than the clip leaves beside the other end's transition.
    mutating func setTransitionDuration(_ duration: CMTime, at edge: TransitionEdge, of clipID: UUID, in timelineID: UUID, layer layerID: UUID) {
        guard let timeline = timeline(id: timelineID),
              let layer = timeline.layer(id: layerID),
              let clip = layer.clips.first(where: { $0.id == clipID }),
              var transition = clip.transition(at: edge)
        else {
            return
        }
        // A joining transition keeps its share before the cut.
        if edge == .leading, let previous = predecessor(joining: clip, among: layer.clips) {
            let share = transition.duration.seconds > 0 ? transition.lead.seconds / transition.duration.seconds : 0.5
            let lead = CMTimeMultiplyByFloat64(duration, multiplier: share)
            if let fit = fittedJoint(duration: duration, lead: lead, outgoing: previous, incoming: clip, in: timeline) {
                transition.duration = fit.duration
                transition.lead = fit.lead
                updateClip(clipID, in: timelineID, layer: layerID) { $0.setTransition(transition, at: edge) }
                return
            }
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

    fileprivate mutating func updateClip(_ clipID: UUID, in timelineID: UUID, layer layerID: UUID, _ change: (inout TimelineClip) -> Void) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(where: { $0.id == clipID })
        else {
            return
        }
        change(&timelines[tIndex].layers[lIndex].clips[cIndex])
    }
}

// MARK: - Joining clips

/// A transition joining two clips at a cut, with what it can draw on.
struct TransitionJoint: Equatable {
    var layerID: UUID
    var outgoing: TimelineClip
    var incoming: TimelineClip
    var transition: ClipTransition
    /// The part played before the cut, as it actually plays.
    var lead: CMTime
    /// Footage past the outgoing clip's out point.
    var spareTail: CMTime
    /// Footage before the incoming clip's in point.
    var spareHead: CMTime

    var cut: CMTime { incoming.startOffset }
    var start: CMTime { CMTimeSubtract(cut, lead) }
    var end: CMTime { CMTimeAdd(start, transition.duration) }
}

/// A change made in a joint's footage editor.
enum JointEdit: Equatable {
    /// Moves the cut, trimming one clip as much as the other is extended
    /// (a roll edit), so the transition draws on different footage.
    case roll(CMTime)
    /// Sets the transition's length and how much of it plays before the cut.
    case place(duration: CMTime, lead: CMTime)
    /// Lengthens the transition by twice a distance (shortens it, when
    /// negative), half on each side, so its center stays where it is.
    case widen(CMTime)
    /// Slips the outgoing clip's footage (positive plays later footage),
    /// which changes what the transition has after the cut.
    case slipOut(CMTime)
    /// Slips the incoming clip's footage, which changes what the transition
    /// has before the cut.
    case slipIn(CMTime)
}

extension EditingProject {
    private func isJoinable(_ clip: TimelineClip) -> Bool {
        guard case .media = clip.source else { return false }
        return playsVideo(clip)
    }

    /// The clip just before `clip` on its layer when they meet at a cut and
    /// a transition can blend their pictures: both are media with pictures.
    func predecessor(joining clip: TimelineClip, among clips: [TimelineClip]) -> TimelineClip? {
        guard isJoinable(clip) else { return nil }
        return clips.first { $0.id != clip.id && $0.endOffset == clip.startOffset && isJoinable($0) }
    }

    /// The clip just after `clip` that a transition at its end would join.
    func successor(joining clip: TimelineClip, among clips: [TimelineClip]) -> TimelineClip? {
        guard isJoinable(clip) else { return nil }
        return clips.first { $0.id != clip.id && $0.startOffset == clip.endOffset && isJoinable($0) }
    }

    /// Footage past the outgoing clip's out point and before the incoming
    /// clip's in point: what a joining transition plays besides the clips.
    func spareFootage(outgoing: TimelineClip, incoming: TimelineClip) -> (tail: CMTime, head: CMTime) {
        let length = sourceDuration(for: outgoing.source) ?? outgoing.trimEnd
        return (CMTimeMaximum(.zero, CMTimeSubtract(length, outgoing.trimEnd)), CMTimeMaximum(.zero, incoming.trimStart))
    }

    /// The length and lead a joining transition can have. Before the cut
    /// the incoming clip plays its spare head, so the lead is at most that
    /// (and no longer than the outgoing clip); after the cut the outgoing
    /// clip plays its spare tail, so the rest is at most that (and leaves
    /// room for the incoming clip's way out). Both land on frames. Nil when
    /// there is less than a frame of spare footage.
    func fittedJoint(
        duration: CMTime,
        lead: CMTime,
        outgoing: TimelineClip,
        incoming: TimelineClip,
        in timeline: Timeline
    ) -> (duration: CMTime, lead: CMTime)? {
        let spare = spareFootage(outgoing: outgoing, incoming: incoming)
        let before = timeline.frameAligned(CMTimeMinimum(spare.head, outgoing.trimmedDuration), .down)
        let insideRoom = CMTimeSubtract(incoming.trimmedDuration, incoming.transitionOut?.duration ?? .zero)
        let after = timeline.frameAligned(CMTimeMinimum(spare.tail, insideRoom), .down)
        let longest = CMTimeAdd(CMTimeMaximum(.zero, before), CMTimeMaximum(.zero, after))
        let frame = timeline.frameDuration
        guard longest >= frame else { return nil }
        let fitted = CMTimeMinimum(CMTimeMaximum(timeline.frameAligned(duration, .nearest), frame), longest)
        let lowest = CMTimeMaximum(.zero, CMTimeSubtract(fitted, after))
        let highest = CMTimeMinimum(CMTimeMaximum(.zero, before), fitted)
        let wanted = timeline.frameAligned(lead, .nearest)
        return (fitted, CMTimeMinimum(CMTimeMaximum(wanted, lowest), highest))
    }

    /// How much of `clip`'s way in plays before its start, over the clip
    /// it joins; nil when it joins none, or there is no spare footage.
    func joinedLead(of clip: TimelineClip, among clips: [TimelineClip]) -> CMTime? {
        guard let transition = clip.transitionIn, let previous = predecessor(joining: clip, among: clips) else { return nil }
        let spare = spareFootage(outgoing: previous, incoming: clip)
        guard spare.tail > .zero || spare.head > .zero else { return nil }
        return CMTimeMaximum(.zero, CMTimeMinimum(CMTimeMinimum(transition.lead, spare.head), CMTimeMinimum(previous.trimmedDuration, transition.duration)))
    }

    /// The joint at the start of `incomingID`, if its way in joins it to
    /// the clip before.
    func joint(at incomingID: UUID, in timelineID: UUID, layer layerID: UUID) -> TransitionJoint? {
        guard let layer = timeline(id: timelineID)?.layer(id: layerID),
              let incoming = layer.clips.first(where: { $0.id == incomingID }),
              let transition = incoming.transitionIn,
              let outgoing = predecessor(joining: incoming, among: layer.clips),
              let lead = joinedLead(of: incoming, among: layer.clips)
        else {
            return nil
        }
        let spare = spareFootage(outgoing: outgoing, incoming: incoming)
        return TransitionJoint(
            layerID: layerID, outgoing: outgoing, incoming: incoming, transition: transition,
            lead: lead, spareTail: spare.tail, spareHead: spare.head
        )
    }

    mutating func applyJointEdit(_ edit: JointEdit, at incomingID: UUID, in timelineID: UUID, layer layerID: UUID) {
        guard let joint = joint(at: incomingID, in: timelineID, layer: layerID),
              let timeline = timeline(id: timelineID)
        else {
            return
        }
        switch edit {
        case .place(let duration, let lead):
            guard let fit = fittedJoint(duration: duration, lead: lead, outgoing: joint.outgoing, incoming: joint.incoming, in: timeline) else { return }
            var transition = joint.transition
            transition.duration = fit.duration
            transition.lead = fit.lead
            updateClip(incomingID, in: timelineID, layer: layerID) { $0.setTransition(transition, at: .leading) }
        case .widen(let delta):
            let duration = CMTimeAdd(joint.transition.duration, CMTimeMultiply(delta, multiplier: 2))
            let lead = CMTimeAdd(joint.lead, delta)
            guard duration > .zero,
                  let fit = fittedJoint(duration: duration, lead: lead, outgoing: joint.outgoing, incoming: joint.incoming, in: timeline)
            else {
                return
            }
            var transition = joint.transition
            transition.duration = fit.duration
            transition.lead = fit.lead
            updateClip(incomingID, in: timelineID, layer: layerID) { $0.setTransition(transition, at: .leading) }
        case .roll(let delta):
            rollCut(joint, by: delta, in: timeline)
        case .slipOut(let delta):
            slipClip(joint.outgoing.id, in: timelineID, layer: layerID, by: delta)
        case .slipIn(let delta):
            slipClip(joint.incoming.id, in: timelineID, layer: layerID, by: delta)
        }
    }

    /// A roll edit: the cut moves by `delta` (onto a frame), the outgoing
    /// clip's out point and the incoming clip's in point with it, so the
    /// two still meet and nothing else on the layer moves. Each clip keeps
    /// at least a frame and can't reveal footage its file doesn't have. The
    /// transition is then fitted to the spare footage left.
    private mutating func rollCut(_ joint: TransitionJoint, by delta: CMTime, in timeline: Timeline) {
        let frame = timeline.frameDuration
        let earliest = CMTimeAdd(joint.outgoing.startOffset, frame)
        let latest = CMTimeSubtract(joint.incoming.endOffset, frame)
        let lowest = CMTimeMaximum(earliest, CMTimeSubtract(joint.cut, joint.spareHead))
        let highest = CMTimeMinimum(latest, CMTimeAdd(joint.cut, joint.spareTail))
        guard highest >= lowest else { return }
        let wanted = timeline.frameAligned(CMTimeAdd(joint.cut, delta), .nearest)
        let newCut = CMTimeMinimum(CMTimeMaximum(wanted, timeline.frameAligned(lowest, .up)), timeline.frameAligned(highest, .down))
        let shift = CMTimeSubtract(newCut, joint.cut)
        guard shift != .zero else { return }

        var outgoing = joint.outgoing
        outgoing.trimEnd = CMTimeAdd(outgoing.trimEnd, shift)
        var incoming = joint.incoming
        incoming.trimStart = CMTimeAdd(incoming.trimStart, shift)
        incoming.startOffset = newCut
        if var transition = incoming.transitionIn,
           let fit = fittedJoint(duration: transition.duration, lead: transition.lead, outgoing: outgoing, incoming: incoming, in: timeline) {
            transition.duration = fit.duration
            transition.lead = fit.lead
            incoming.transitionIn = transition
        }
        guard let tIndex = timelines.firstIndex(where: { $0.id == timeline.id }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == joint.layerID })
        else {
            return
        }
        for (index, clip) in timelines[tIndex].layers[lIndex].clips.enumerated() {
            if clip.id == outgoing.id { timelines[tIndex].layers[lIndex].clips[index] = outgoing }
            if clip.id == incoming.id { timelines[tIndex].layers[lIndex].clips[index] = incoming }
        }
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
    /// Where the way in starts: before the clip when it joins the clip
    /// before, by `lead`.
    var leadingStart: CMTime
    /// The frame of the timeline the clip is on.
    var frameSize: CGSize

    init?(clip: TimelineClip, frameSize: CGSize, lead: CMTime = .zero) {
        let durations = clip.effectiveTransitionDurations(lead: lead)
        if let transition = clip.transitionIn, CMTimeAdd(durations.leading, lead) > .zero {
            leading = (transition.kind, CMTimeAdd(durations.leading, lead), transition.curve)
        }
        if let transition = clip.transitionOut, durations.trailing > .zero {
            trailing = (transition.kind, durations.trailing, transition.curve)
        }
        guard leading != nil || trailing != nil else { return nil }
        start = clip.startOffset
        end = clip.endOffset
        leadingStart = CMTimeSubtract(clip.startOffset, lead)
        self.frameSize = frameSize
    }

    /// What the transitions do to the clip at `time`, in its timeline's
    /// frame: how opaque it is, how it is moved, and the part of the frame
    /// it may show (nil when it isn't wiped).
    struct Effect {
        var opacity: Double = 1
        var transform: CGAffineTransform = .identity
        var visibleRect: CGRect?
        var lumaReveal: LumaReveal?
    }

    var hasWipe: Bool {
        [leading?.kind, trailing?.kind].contains { $0?.isWipe == true }
    }

    var hasLumaReveal: Bool {
        leading?.kind == .filmDissolve || trailing?.kind == .filmDissolve
    }

    /// Each transition's curve maps the fraction of its length that has
    /// passed to how far it has got; a way in shows more of the clip as it
    /// goes, a way out less.
    func effect(at time: CMTime) -> Effect {
        var effect = Effect()
        if let leading {
            let elapsed = CMTimeSubtract(time, leadingStart).seconds / leading.duration.seconds
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
        if let leading { ranges.append(CMTimeRange(start: leadingStart, duration: leading.duration)) }
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
        case .filmDissolve:
            // What comes next shows through brightest first: the clip itself
            // on the way in, whatever is under it on the way out.
            effect.lumaReveal = entering
                ? LumaReveal(progress: v, keysIncoming: true)
                : LumaReveal(progress: 1 - v, keysIncoming: false)
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

/// A film dissolve at one moment: the following picture shows wherever it
/// is brighter than a threshold that falls from white to black as
/// `progress` goes from 0 to 1, with a soft edge.
struct LumaReveal: Equatable, Sendable {
    var progress: Double
    /// True when the clip itself is the following picture (its way in);
    /// false when what is under it is (its way out).
    var keysIncoming: Bool

    /// Width of the soft edge, in brightness.
    static let softness = 0.1

    /// The mask is `clamp(gain * luma + bias)`: nothing at progress 0 and
    /// everything at 1, even for pure white and pure black.
    var gainAndBias: (gain: Double, bias: Double) {
        let s = Self.softness
        let threshold = (1 + s) - min(max(progress, 0), 1) * (1 + 2 * s)
        return (1 / (2 * s), (s - threshold) / (2 * s))
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
