import CoreMedia
import Foundation

/// A clip's sound fading in or out under one of its transitions, or under
/// a transition of the clip it is joined to. The gain follows the
/// transition's curve and is equal power, so two clips crossfading through
/// a cut keep their loudness across it. See docs/audio.md, "Under
/// transitions".
struct AudioFade: Equatable, Sendable {
    /// Where it starts and ends, in seconds of root time.
    var start: Double
    var end: Double
    /// Whether the sound comes in (from silence) or goes out (to it).
    var rising: Bool
    var curve: TransitionCurve = .linear

    /// The gain at `seconds` of root time: silent before a rising fade and
    /// after a falling one, and full on the other side.
    func gain(at seconds: Double) -> Float {
        guard end > start else { return 1 }
        let progress = curve.value(at: (seconds - start) / (end - start)).clamped(between: 0, and: 1)
        let angle = progress * .pi / 2
        return Float(rising ? sin(angle) : cos(angle))
    }

    /// The fade moved from a timeline's own time into root time.
    func shifted(by offset: CMTime) -> AudioFade {
        var shifted = self
        shifted.start += offset.seconds
        shifted.end += offset.seconds
        return shifted
    }
}

extension EditingProject {
    /// The fades `clip`'s sound plays through under transitions, in its
    /// timeline's time, and how much sound it plays past each end for
    /// them: at a joined cut each clip's sound carries on through the
    /// transition on its spare footage, as its picture does, so the two
    /// crossfade instead of one cutting off.
    ///
    /// - Its way in rises over the transition, which at a joined cut
    ///   starts `lead` before the cut, over the end of the clip before.
    /// - Its way out falls over the transition.
    /// - The way in of the clip after, joined to it, makes it fall over
    ///   that transition, playing on past its out point after the cut.
    /// - The way out of the clip before, joined to it, makes it rise over
    ///   that transition, starting before its in point.
    func audioFades(of clip: TimelineClip, among clips: [TimelineClip]) -> (fades: [AudioFade], head: CMTime, tail: CMTime) {
        var fades: [AudioFade] = []
        var head = CMTime.zero, tail = CMTime.zero
        func fade(from start: CMTime, for length: CMTime, rising: Bool, curve: TransitionCurve) {
            fades.append(AudioFade(start: start.seconds, end: CMTimeAdd(start, length).seconds, rising: rising, curve: curve))
        }

        let lead = joinedLead(of: clip, among: clips) ?? .zero
        let durations = clip.effectiveTransitionDurations(lead: lead)
        if let transition = clip.transitionIn {
            let length = CMTimeAdd(durations.leading, lead)
            if length > .zero {
                fade(from: CMTimeSubtract(clip.startOffset, lead), for: length, rising: true, curve: transition.curve)
                head = lead
            }
        }
        if let transition = clip.transitionOut, durations.trailing > .zero {
            fade(from: CMTimeSubtract(clip.endOffset, durations.trailing), for: durations.trailing, rising: false, curve: transition.curve)
        }

        if let next = successor(joining: clip, among: clips), let transition = next.transitionIn,
           let nextLead = joinedLead(of: next, among: clips) {
            let after = next.effectiveTransitionDurations(lead: nextLead).leading
            let length = CMTimeAdd(after, nextLead)
            if length > .zero {
                fade(from: CMTimeSubtract(next.startOffset, nextLead), for: length, rising: false, curve: transition.curve)
                tail = CMTimeMinimum(after, spareFootage(outgoing: clip, incoming: next).tail)
            }
        }
        if let previous = predecessor(joining: clip, among: clips), let transition = previous.transitionOut {
            let before = previous.effectiveTransitionDurations(lead: joinedLead(of: previous, among: clips) ?? .zero).trailing
            if before > .zero {
                fade(from: CMTimeSubtract(clip.startOffset, before), for: before, rising: true, curve: transition.curve)
                head = CMTimeMaximum(head, CMTimeMinimum(before, spareFootage(outgoing: previous, incoming: clip).head))
            }
        }
        return (fades, head, tail)
    }
}
