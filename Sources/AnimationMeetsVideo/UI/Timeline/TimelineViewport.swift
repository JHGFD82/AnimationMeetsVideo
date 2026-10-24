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
    /// How far the tracks are scrolled, always within `0...maxScrollX`.
    let scrollX: CGFloat

    static let maximumFrameWidth: CGFloat = 80

    /// - Parameters:
    ///   - requestedPixelsPerSecond: The chosen zoom, or nil to fit the span.
    ///   - requestedScrollX: The chosen scroll offset; clamped to the content.
    init(durationSeconds: Double, frameRate: Double, width: CGFloat, requestedPixelsPerSecond: CGFloat?, requestedScrollX: CGFloat) {
        let duration = max(0, durationSeconds)
        contentSeconds = duration + max(1, duration * 0.05)
        self.width = max(1, width)
        fitPixelsPerSecond = self.width / CGFloat(contentSeconds)
        maxPixelsPerSecond = max(fitPixelsPerSecond, CGFloat(max(frameRate, 1)) * Self.maximumFrameWidth)
        pixelsPerSecond = (requestedPixelsPerSecond ?? fitPixelsPerSecond).clamped(between: fitPixelsPerSecond, and: maxPixelsPerSecond)
        let maxScroll = max(0, CGFloat(contentSeconds) * pixelsPerSecond - self.width)
        scrollX = requestedScrollX.clamped(between: 0, and: maxScroll)
    }

    var contentWidth: CGFloat { CGFloat(contentSeconds) * pixelsPerSecond }

    var maxScrollX: CGFloat { max(0, contentWidth - width) }

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
