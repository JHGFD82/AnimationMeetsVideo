import CoreGraphics
import SwiftUI

/// The edge of a zoom, the way the system's own zoomable views have one:
/// a zoom pushed past its limit stretches the view instead, against more
/// resistance the further it goes, and springs back when let go. The limit
/// then reads as an edge rather than as a control that stopped answering.
///
/// It doesn't know a view's limits. A zoom goes through `zoom(by:about:
/// pinching:_:)`, whose closure zooms the view as far as the view allows
/// and says how far that was; what was held back becomes the stretch.
/// Draw the stretch with `rubberBand(_:axis:)`.
struct RubberBandZoom: RubberBand {
    /// What brings a stretch back.
    enum Settle: Equatable {
        /// Nothing is stretched.
        case resting
        /// A pinch is holding it; it springs back when the fingers lift.
        case held
        /// The fingers lifted: spring back now.
        case lifted
        /// A button, key, wheel or dial pushed it: spring back once the
        /// pushes stop coming.
        case nudged
    }

    /// How far, in log of the zoom, zooming was pushed past a limit: above
    /// 0 in past the closest, below 0 out past the farthest.
    private(set) var stretch = 0.0
    /// Where the view stretches from, as a share of its length.
    private(set) var anchor: CGFloat = 0.5
    private(set) var settle = Settle.resting

    /// The most a stretch scales the view, either way: a fifth.
    static let reach = 0.2

    /// How much of what a limit holds back a zoom that isn't a pinch (a key,
    /// a button, a wheel) stretches the view by.
    static let nudgeShare = 0.3

    /// Zooms by `factor` (above 1 zooms in) through `apply`, which zooms
    /// the view by the factor it's given, as far as the view's limits
    /// allow, and returns the factor it managed. What a limit holds back
    /// stretches the view about `anchor`, a share of its length. Zooming
    /// back the other way takes up a stretch before the view zooms again.
    mutating func zoom(by factor: Double, about anchor: CGFloat, pinching: Bool, _ apply: (Double) -> Double) {
        guard factor > 0, factor.isFinite else { return }
        var asked = log(factor)
        if stretch != 0, asked * stretch < 0 {
            let back = asked > 0 ? min(asked, -stretch) : max(asked, -stretch)
            stretch += back
            asked -= back
        }
        if asked != 0 {
            let got = apply(exp(asked))
            // A view that zoomed all the way leaves rounding, not a stretch.
            // A key or a button pushes less than a pinch does: one press
            // past the limit is a nudge, not a jump.
            if got > 0, got.isFinite, abs(asked - log(got)) > 1e-6 {
                stretch += (asked - log(got)) * (pinching ? 1 : Self.nudgeShare)
            }
        }
        if abs(stretch) < 1e-6 { stretch = 0 }
        if stretch != 0 { self.anchor = min(max(anchor, 0), 1) }
        settle = stretch == 0 ? .resting : (pinching ? .held : .nudged)
    }

    /// The pinch's fingers lifted.
    mutating func endPinch() {
        settle = stretch == 0 ? .resting : .lifted
    }

    /// Lets go of the stretch. `rubberBand(_:axis:)` calls this, animated.
    mutating func release() {
        stretch = 0
        settle = .resting
    }

    /// How much the view is scaled along the zoom's axis: up to `reach`
    /// wider when stretched in, narrower when stretched out, closing in
    /// more slowly as it goes.
    var scale: CGFloat {
        let give = Self.reach * (1 - exp(-2.5 * abs(stretch)))
        return CGFloat(stretch > 0 ? 1 + give : 1 - give)
    }
}

extension Design.Motion {
    /// A stretched zoom springing back: lively, so the edge reads.
    static let rubberBand = Animation.spring(response: 0.32, dampingFraction: 0.55)
}

extension View {
    /// Draws `band`'s stretch along `axis` and springs it back when it is
    /// let go. A view that shows one zoom in several places draws the rest
    /// with `rubberBandStretch(_:axis:)`, so it springs back only once.
    func rubberBand(_ band: Binding<RubberBandZoom>, axis: Axis = .horizontal) -> some View {
        rubberBandStretch(band.wrappedValue, axis: axis)
            .modifier(RubberBandSettling(band: band))
    }

    /// Draws `band`'s stretch along `axis`, without springing it back.
    func rubberBandStretch(_ band: RubberBandZoom, axis: Axis = .horizontal) -> some View {
        // Reduced motion keeps the hard stop.
        let scale = Design.Motion.isReduced ? 1 : band.scale
        return scaleEffect(
            x: axis == .horizontal ? scale : 1,
            y: axis == .vertical ? scale : 1,
            anchor: axis == .horizontal ? UnitPoint(x: band.anchor, y: 0.5) : UnitPoint(x: 0.5, y: band.anchor)
        )
    }

    /// Springs `band` back when it is let go, without drawing it.
    func rubberBandSettling<Band: RubberBand>(_ band: Binding<Band>) -> some View {
        modifier(RubberBandSettling(band: band))
    }
}

/// A view's edge, pushed past and springing back: a zoom's
/// (`RubberBandZoom`) or a scroll's (`RubberBandScroll`).
protocol RubberBand: Equatable {
    var settle: RubberBandZoom.Settle { get }
    /// Lets go of the stretch; `rubberBandSettling` calls this, animated.
    mutating func release()
}

/// Springs a stretch back: at once when a pinch lifts, and a moment after
/// the last push otherwise, so a run of wheel clicks, key presses or
/// scroll events (a swipe's momentum among them) holds it until the run
/// ends.
private struct RubberBandSettling<Band: RubberBand>: ViewModifier {
    @Binding var band: Band

    func body(content: Content) -> some View {
        content.task(id: band) {
            switch band.settle {
            case .resting, .held:
                return
            case .nudged:
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
            case .lifted:
                break
            }
            withAnimation(Design.Motion.respecting(Design.Motion.rubberBand)) { band.release() }
        }
    }
}
