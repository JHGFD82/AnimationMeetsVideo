import AppKit
import CoreGraphics
import SwiftUI

/// What a scroll event is, for `RubberBandScroll` to know when it is let
/// go: fingers moving on the trackpad, the fingers lifting, the glide
/// after a swipe, or a mouse wheel's click.
enum ScrollInputPhase: Equatable {
    case touching, lifted, momentum, wheel

    init(_ event: NSEvent) {
        if !event.momentumPhase.isEmpty {
            self = .momentum
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            self = .lifted
        } else if !event.phase.isEmpty {
            self = .touching
        } else {
            self = .wheel
        }
    }
}

/// The edge of a scroll that the editor does itself (the timeline's time,
/// the Beat Match waveform, the keyframe graph's time), the way the
/// system's scroll views have one: scrolled past the start or the end, the
/// content slides on against more resistance the further it goes, and
/// springs back when the scrolling stops. Only on an axis that also
/// zooms, as zoomed-in content is what invites scrolling to its end;
/// `RubberBandZoom` is the zoom's edge.
///
/// Like the zoom's, it doesn't know the view's edges: a scroll goes
/// through `scroll(by:_:)`, whose closure scrolls the view as far as it
/// can and says how far that was. Draw it with `rubberBandScroll(_:)`.
struct RubberBandScroll: RubberBand {
    /// Points scrolled past an edge, before resistance: below 0 before the
    /// start, above 0 past the end.
    private(set) var overscroll: CGFloat = 0
    private(set) var settle = RubberBandZoom.Settle.resting
    /// Set once a swipe's glide has bounced, or the fingers lifted past an
    /// edge: the rest of that glide is let go, so it bounces once and at
    /// once rather than holding the content out until the glide ends.
    private var absorbsMomentum = false

    /// The most the content slides past an edge: a small share of the
    /// view, and never more than a thumb's width, so it reads as an edge,
    /// as the zoom's fifth does, rather than as more to scroll to.
    static let reach: CGFloat = 0.08
    static let largestReach: CGFloat = 60

    /// Scrolls by `delta` points (above 0 toward the end) through `apply`,
    /// which scrolls the view as far as its edges allow and returns how far
    /// it went. What an edge holds back pushes past it instead; scrolling
    /// back takes that up before the view moves again.
    ///
    /// The phase says when to spring back: as the fingers lift; at once
    /// when a swipe's glide reaches the edge, the rest of the glide let go;
    /// a moment after a mouse wheel's last click.
    mutating func scroll(by delta: CGFloat, phase: ScrollInputPhase = .wheel, _ apply: (CGFloat) -> CGFloat) {
        switch phase {
        case .touching, .wheel:
            absorbsMomentum = false
        case .momentum:
            if absorbsMomentum { return }
        case .lifted:
            break
        }
        let before = overscroll
        if delta != 0, delta.isFinite { push(delta, apply) }
        switch phase {
        case .touching:
            settle = overscroll == 0 ? .resting : .held
        case .wheel:
            settle = overscroll == 0 ? .resting : .nudged
        case .lifted:
            absorbsMomentum = overscroll != 0
            settle = overscroll == 0 ? .resting : .lifted
        case .momentum:
            // The glide reached the edge: one bounce, now.
            if overscroll != 0, before == 0 || overscroll != before {
                absorbsMomentum = true
                settle = .lifted
            }
        }
    }

    private mutating func push(_ delta: CGFloat, _ apply: (CGFloat) -> CGFloat) {
        var asked = delta
        if overscroll != 0, asked * overscroll < 0 {
            let back = asked > 0 ? min(asked, -overscroll) : max(asked, -overscroll)
            overscroll += back
            asked -= back
        }
        if asked != 0 {
            let moved = apply(asked)
            if abs(asked - moved) > 0.01 { overscroll += asked - moved }
        }
        if abs(overscroll) < 0.01 { overscroll = 0 }
    }

    mutating func release() {
        overscroll = 0
        settle = .resting
    }

    /// How far to draw the content moved, for a view `length` points long:
    /// against the scroll, closing in quickly on `reach` of the length (at
    /// most `largestReach`), so even a swipe's momentum only nudges it.
    func offset(length: CGFloat) -> CGFloat {
        guard overscroll != 0, length > 0 else { return 0 }
        let cap = min(length * Self.reach, Self.largestReach)
        let give = cap * (1 - exp(-abs(overscroll) / cap))
        return overscroll > 0 ? -give : give
    }
}

extension View {
    /// Draws `band`'s push past an edge, sideways, for a view `length`
    /// points across, without springing it back (`rubberBandSettling`).
    /// Reduced motion keeps the hard stop.
    func rubberBandScroll(_ band: RubberBandScroll, length: CGFloat) -> some View {
        offset(x: Design.Motion.isReduced ? 0 : band.offset(length: length))
    }
}
