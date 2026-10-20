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
@MainActor @Observable
final class LaneViewport {
    /// The control column's width: at least `EffectsPanelMetrics.labelWidth`,
    /// and the widest it has needed since the clip was selected, so it
    /// doesn't resize back as a value shortens.
    var labelWidth = EffectsPanelMetrics.labelWidth
    /// The width of the lanes' window, and of the lanes themselves when
    /// not zoomed in.
    private(set) var visibleWidth: CGFloat = 0
    /// How many times wider than the window the lanes are: 1 shows the
    /// whole clip.
    private(set) var zoom: CGFloat = 1
    /// How far the lanes are scrolled, within `0...maxScrollX`.
    private(set) var scrollX: CGFloat = 0
    /// The closest zoom: one frame `TimelineViewport.maximumFrameWidth` wide.
    private(set) var maxZoom: CGFloat = 1
    /// What a zoom past either limit stretches, and a scroll past either
    /// end slides.
    var zoomBand = RubberBandZoom()
    var scrollBand = RubberBandScroll()

    var maxScrollX: CGFloat { max(0, visibleWidth * zoom - visibleWidth) }

    /// Takes the window's width and the closest zoom, as the panel is
    /// resized or the clip changes.
    func fit(width: CGFloat, maxZoom: CGFloat) {
        visibleWidth = width
        self.maxZoom = max(1, maxZoom)
        zoom = min(zoom, self.maxZoom)
        scrollX = min(max(0, scrollX), maxScrollX)
    }

    /// Shows the whole clip again.
    func reset() {
        labelWidth = EffectsPanelMetrics.labelWidth
        zoom = 1
        scrollX = 0
        zoomBand = RubberBandZoom()
        scrollBand = RubberBandScroll()
    }

    /// Zooms by `factor` (above 1 zooms in) about `x` in the window. Past
    /// the whole clip or the closest zoom the lanes stretch instead.
    func zoom(by factor: Double, aboutX x: CGFloat, pinching: Bool) {
        var band = zoomBand
        band.zoom(by: factor, about: visibleWidth > 0 ? x / visibleWidth : 0.5, pinching: pinching) { factor in
            let before = zoom
            zoom = min(max(zoom * CGFloat(factor), 1), maxZoom)
            scrollX = min(max(0, (scrollX + x) * zoom / before - x), maxScrollX)
            return Double(zoom / before)
        }
        zoomBand = band
    }

    /// The pinch's fingers lifted: a stretch springs back.
    func endPinch() { zoomBand.endPinch() }

    /// Scrolls sideways by `points`, as a trackpad or a wheel does. Past
    /// either end the lanes slide on and spring back.
    func scroll(by points: CGFloat, phase: ScrollInputPhase) {
        var band = scrollBand
        band.scroll(by: points, phase: phase) { points in
            let before = scrollX
            scrollX = min(max(0, before + points), maxScrollX)
            return scrollX - before
        }
        scrollBand = band
    }

    /// A step of zoom or scroll for VoiceOver and the keyboard, which
    /// can't pinch or swipe.
    func zoomStep(in zoomingIn: Bool) {
        zoom(by: zoomingIn ? 2 : 0.5, aboutX: visibleWidth / 2, pinching: false)
    }

    func scrollStep(later: Bool) {
        scroll(by: (later ? 1 : -1) * visibleWidth / 2, phase: .wheel)
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
        let width = viewport.visibleWidth
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
