import CoreGraphics
import CoreMedia

/// The visible slice of the timeline's track area: how many points one
/// second takes and how far the tracks are scrolled. The timeline owns its
/// horizontal scrolling instead of leaving it to a scroll view, so a zoom
/// can move the scale and the scroll offset together and keep the time
/// under the pointer (or the playhead) where it was.
struct TimelineViewport: Equatable {
    /// Seconds the track area spans: the timeline plus room after its end
    /// to drag clips into.
    let contentSeconds: Double
    /// Width of the visible track area, in points.
    let width: CGFloat
    /// The scale that fits the whole span into `width`. Zooming out stops here.
    let fitPixelsPerSecond: CGFloat
    /// The closest zoom: one frame `maximumFrameWidth` points wide.
    let maxPixelsPerSecond: CGFloat
    let pixelsPerSecond: CGFloat
    /// Empty room before 0:00 the tracks can be scrolled into, left by the
    /// names column narrowing while they were scrolled to the start (see
    /// `keepingPlace(asLeftEdgeMovesBy:)`).
    let leadIn: CGFloat
    /// How far the tracks are scrolled, always within `minScrollX...maxScrollX`:
    /// negative only into the lead-in.
    let scrollX: CGFloat

    static let maximumFrameWidth: CGFloat = 80

    /// - Parameters:
    ///   - requestedPixelsPerSecond: The chosen zoom, or nil to fit the span.
    ///   - requestedScrollX: The chosen scroll offset; clamped to the
    ///     content and the lead-in.
    ///   - leadIn: Room before 0:00 the scroll may go into.
    init(
        durationSeconds: Double, frameRate: Double, width: CGFloat, requestedPixelsPerSecond: CGFloat?, requestedScrollX: CGFloat,
        leadIn: CGFloat = 0
    ) {
        let duration = max(0, durationSeconds)
        contentSeconds = duration + max(1, duration * 0.05)
        self.width = max(1, width)
        fitPixelsPerSecond = self.width / CGFloat(contentSeconds)
        maxPixelsPerSecond = max(fitPixelsPerSecond, CGFloat(max(frameRate, 1)) * Self.maximumFrameWidth)
        pixelsPerSecond = (requestedPixelsPerSecond ?? fitPixelsPerSecond).clamped(between: fitPixelsPerSecond, and: maxPixelsPerSecond)
        let maxScroll = max(0, CGFloat(contentSeconds) * pixelsPerSecond - self.width)
        self.leadIn = max(0, leadIn)
        scrollX = requestedScrollX.clamped(between: -self.leadIn, and: maxScroll)
    }

    var contentWidth: CGFloat { CGFloat(contentSeconds) * pixelsPerSecond }

    var maxScrollX: CGFloat { max(0, contentWidth - width) }

    var minScrollX: CGFloat { -leadIn }

    var isFitted: Bool { pixelsPerSecond <= fitPixelsPerSecond * 1.0001 }

    /// Where `seconds` is drawn, in the visible area's own coordinates.
    func x(atSeconds seconds: Double) -> CGFloat {
        CGFloat(seconds) * pixelsPerSecond - scrollX
    }

    func seconds(atX x: CGFloat) -> Double {
        Double((x + scrollX) / pixelsPerSecond)
    }

    /// The visible span, in the tracks' own (unscrolled) coordinates.
    var visibleContentX: ClosedRange<CGFloat> { scrollX...(scrollX + width) }

    var visibleSeconds: ClosedRange<Double> { seconds(atX: 0)...seconds(atX: width) }

    /// The scale and scroll offset after zooming to `pixelsPerSecond`
    /// (clamped to the allowed range) with the moment at `seconds` held at
    /// visible x `anchorX`. A nil scale means the zoom reached the fit.
    func zoomed(to pixelsPerSecond: CGFloat, keeping seconds: Double, atX anchorX: CGFloat) -> (pixelsPerSecond: CGFloat?, scrollX: CGFloat) {
        let scale = pixelsPerSecond.clamped(between: fitPixelsPerSecond, and: maxPixelsPerSecond)
        let scroll = CGFloat(seconds) * scale - anchorX
        return (scale <= fitPixelsPerSecond * 1.0001 ? nil : scale, scroll)
    }

    /// The scale and scroll offset that leave every moment where it is in
    /// the window when the tracks' left edge moves right by `shift` points
    /// (the names column widening, or narrowing for a negative one), the
    /// tracks losing that much width. The scale stays unless the new width
    /// needs a closer one to fit, and a scale that is the new fit is nil,
    /// so widening and narrowing again brings a fitted timeline back to
    /// the fit.
    ///
    /// Narrowing with the tracks scrolled less than `-shift` from the start
    /// would need a scroll before 0:00: that much is `leadIn`, empty room
    /// before the start, so nothing moves. The scale is then kept even if
    /// it is the fit, since a fitted timeline doesn't scroll.
    func keepingPlace(asLeftEdgeMovesBy shift: CGFloat) -> (pixelsPerSecond: CGFloat?, scrollX: CGFloat, leadIn: CGFloat) {
        let fit = max(1, width - shift) / CGFloat(contentSeconds)
        let scale = pixelsPerSecond.clamped(between: fit, and: max(fit, maxPixelsPerSecond))
        let scroll = scrollX + shift
        guard scroll >= 0 else { return (scale, scroll, -scroll) }
        return (scale <= fit * 1.0001 ? nil : scale, scroll, 0)
    }

    /// The scale and scroll offset that fit `start...end` into the width
    /// but for `margin` (a share of the width) either side, centered. A
    /// span too short for the closest zoom is centered at that zoom; one
    /// too long for the fit gets the fit.
    func fitting(_ start: Double, _ end: Double, margin: CGFloat) -> (pixelsPerSecond: CGFloat?, scrollX: CGFloat) {
        let span = max(end - start, .ulpOfOne)
        let scale = width * (1 - 2 * margin) / CGFloat(span)
        return zoomed(to: scale, keeping: (start + end) / 2, atX: width / 2)
    }

    /// Zoom position on a 0...1 scale that is even in ratio, so each step of
    /// a slider multiplies the scale by the same amount.
    var zoomFraction: Double {
        ZoomScale.fraction(of: Double(pixelsPerSecond), in: zoomScale)
    }

    func pixelsPerSecond(atZoomFraction fraction: Double) -> CGFloat {
        CGFloat(ZoomScale.zoom(atFraction: fraction, in: zoomScale))
    }

    /// The zooms the slider spans, from the fit to the closest.
    private var zoomScale: ClosedRange<Double> {
        Double(fitPixelsPerSecond)...Double(maxPixelsPerSecond)
    }
}
