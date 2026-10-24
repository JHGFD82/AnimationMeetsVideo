import CoreMedia
import Observation
import SwiftUI

/// How the effects panel lays out its control column and the lanes beside
/// it: the column is as wide as its widest row needs (so a large value
/// never runs into the lanes), and the lanes take the rest, which they can
/// be zoomed and scrolled across, past either end of which they bounce, as
/// the timeline's do.
///
/// It is a class the lanes read as they draw (`LaneWindow`), so a scroll
/// redraws only them, not the rows' controls, which are kept between
/// redraws (`StackRow`).
///
/// It zooms and scrolls as a `SecondsViewport`, in the lanes' points at
/// the whole clip's zoom, which stand for the clip's time: the lanes span
/// `0...viewWidth` of them, and a zoom of 2 shows a point of the window
/// for every half of one.
@MainActor @Observable
final class LaneViewport: SecondsViewport {
    /// The control column's width: at least `EffectsPanelMetrics.labelWidth`,
    /// and the widest it has needed since the clip was selected, so it
    /// doesn't resize back as a value shortens.
    var labelWidth = EffectsPanelMetrics.labelWidth
    /// The width of the lanes' window, and of the lanes themselves when
    /// not zoomed in.
    private(set) var viewWidth: CGFloat = 0
    /// The left edge and the zoom, in the lanes' points at the whole
    /// clip's zoom.
    var visibleStart: Double = 0
    var secondsPerPoint: Double = 1
    /// The closest zoom: one frame `TimelineViewport.maximumFrameWidth` wide.
    private(set) var maxZoom: CGFloat = 1
    /// What a zoom past either limit stretches, and a scroll past either
    /// end slides.
    var zoomBand = RubberBandZoom()
    var scrollBand = RubberBandScroll()

    var viewBounds: (start: Double, end: Double) { (0, Double(viewWidth)) }
    var closestZoom: Double { 1 / Double(maxZoom) }
    var farthestZoom: Double { 1 }
    var zoomFocus: Double { seconds(atX: viewWidth / 2) }

    /// How many times wider than the window the lanes are: 1 shows the
    /// whole clip.
    var zoom: CGFloat { CGFloat(1 / secondsPerPoint) }
    /// How far the lanes are scrolled, within `0...maxScrollX`.
    var scrollX: CGFloat { CGFloat(visibleStart / secondsPerPoint) }
    var maxScrollX: CGFloat { max(0, viewWidth * zoom - viewWidth) }

    /// Takes the window's width and the closest zoom, as the panel is
    /// resized or the clip changes. The zoom and the scroll, in points,
    /// stay as they were as far as they still fit.
    func fit(width: CGFloat, maxZoom: CGFloat) {
        let scroll = scrollX
        viewWidth = width
        self.maxZoom = max(1, maxZoom)
        secondsPerPoint = max(secondsPerPoint, closestZoom)
        visibleStart = Double(scroll) * secondsPerPoint
        clampView()
    }

    /// Shows the whole clip again.
    func reset() {
        labelWidth = EffectsPanelMetrics.labelWidth
        secondsPerPoint = 1
        visibleStart = 0
        zoomBand = RubberBandZoom()
        scrollBand = RubberBandScroll()
    }

    /// A step of zoom or scroll for VoiceOver and the keyboard, which
    /// can't pinch or swipe.
    func zoomStep(in zoomingIn: Bool) {
        zoomingIn ? zoomIn() : zoomOut()
    }

    func scrollStep(later: Bool) {
        scroll(byPoints: (later ? 1 : -1) * viewWidth / 2)
    }
}

/// The width the widest row's controls need, which `LaneViewport` gives
/// the control column.
struct ControlColumnWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A lane (or the ruler, or the playhead's line) in its window of the
/// zoomed and scrolled lanes. What it holds is laid out at the zoomed
/// width, in the lanes' own coordinates, so what it does with a point
/// doesn't change with the scroll.
struct LaneWindow<Content: View>: View {
    @Environment(LaneViewport.self) private var viewport
    @ViewBuilder let content: () -> Content

    var body: some View {
        let width = viewport.viewWidth
        content()
            .offset(x: -viewport.scrollX)
            .frame(width: width, alignment: .leading)
            .clipped()
            .rubberBandStretch(viewport.zoomBand)
            .rubberBandScroll(viewport.scrollBand, length: width)
            .frame(width: width, alignment: .leading)
            .clipped()
    }
}

/// A row's controls, in the control column.
struct ControlColumn<Content: View>: View {
    @Environment(LaneViewport.self) private var viewport
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().frame(width: viewport.labelWidth, alignment: .leading)
    }
}
