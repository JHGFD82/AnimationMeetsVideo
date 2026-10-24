import CoreGraphics

/// A view of seconds laid across a width, as the motion designer's lanes
/// and Beat Match's waveform are: scrolled and zoomed with rubber-band
/// edges (`RubberBandZoom`, `RubberBandScroll`), and zoomed in about a
/// focus. The conforming session keeps the state, since it is observed,
/// and says what it shows and how a resize changes the zoom.
@MainActor
protocol SecondsViewport: AnyObject {
    /// The left edge, in seconds, and the zoom.
    var visibleStart: Double { get set }
    var secondsPerPoint: Double { get set }
    var viewWidth: CGFloat { get }
    var zoomBand: RubberBandZoom { get set }
    var scrollBand: RubberBandScroll { get set }

    /// The seconds there are to show: nothing past either end is.
    var viewBounds: (start: Double, end: Double) { get }
    var closestZoom: Double { get }
    var farthestZoom: Double { get }
    /// Where zooming in and out, and the zoom slider, zoom about.
    var zoomFocus: Double { get }
}

extension SecondsViewport {
    /// Zooms by `factor` (above 1 zooms in) about a point `x` in the view.
    /// Zooming past the farthest or the closest zoom stretches the view
    /// instead (`zoomBand`), until the pinch lifts, or at once for any
    /// other zoom.
    func zoom(by factor: Double, aboutX x: CGFloat, pinching: Bool = false) {
        var band = zoomBand
        band.zoom(by: factor, about: viewWidth > 0 ? x / viewWidth : 0.5, pinching: pinching) { factor in
            let anchor = seconds(atX: x)
            let before = secondsPerPoint
            secondsPerPoint = min(max(secondsPerPoint / factor, closestZoom), farthestZoom)
            visibleStart = anchor - Double(x) * secondsPerPoint
            clampView()
            return before / secondsPerPoint
        }
        zoomBand = band
    }

    /// The pinch's fingers lifted: the stretch springs back.
    func endPinch() { zoomBand.endPinch() }

    /// Scrolls the view sideways; past its ends it slides on and springs
    /// back (`scrollBand`).
    func scroll(byPoints points: CGFloat, phase: ScrollInputPhase = .wheel) {
        var band = scrollBand
        band.scroll(by: points, phase: phase) { points in
            let before = visibleStart
            visibleStart += Double(points) * secondsPerPoint
            clampView()
            return CGFloat((visibleStart - before) / secondsPerPoint)
        }
        scrollBand = band
    }

    /// The start of what there is to show sits at the left edge at most,
    /// and its end at the right edge at least, while the whole fits.
    func clampView() {
        let span = Double(viewWidth) * secondsPerPoint
        let bounds = viewBounds
        visibleStart = min(max(visibleStart, bounds.start), max(bounds.start, bounds.end - span))
    }

    func zoomIn() { zoom(by: 2, aboutX: x(of: zoomFocus)) }
    func zoomOut() { zoom(by: 0.5, aboutX: x(of: zoomFocus)) }

    /// The zoom as its slider shows it (`ZoomSlider`): 0 the farthest, 1
    /// the closest. Moving it zooms about where zooming in does.
    var zoomFraction: Double {
        get { ZoomScale.fraction(of: 1 / secondsPerPoint, in: zoomRange) }
        set {
            let factor = ZoomScale.factor(from: 1 / secondsPerPoint, toFraction: newValue, in: zoomRange)
            zoom(by: factor, aboutX: x(of: zoomFocus))
        }
    }

    /// The zooms the slider spans, as points per second.
    private var zoomRange: ClosedRange<Double> {
        (1 / farthestZoom)...max(1 / closestZoom, 1 / farthestZoom)
    }

    func x(of seconds: Double) -> CGFloat { CGFloat((seconds - visibleStart) / secondsPerPoint) }
    func seconds(atX x: CGFloat) -> Double { visibleStart + Double(x) * secondsPerPoint }
}
