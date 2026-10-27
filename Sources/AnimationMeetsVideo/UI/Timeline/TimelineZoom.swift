import CoreMedia
import SwiftUI

// Zooming, scrolling and scrubbing a timeline.
extension TimelineView {
    /// Pinch and Option-scroll zoom about the pointer. Past the fit or
    /// the closest zoom the tracks stretch instead (`zoomBand`).
    func zoom(_ laidOut: TimelineViewport, by factor: CGFloat, aboutX x: CGFloat, pinching: Bool = false) {
        var band = viewportModel.zoomBand
        band.zoom(by: Double(factor), about: x / max(laidOut.width, 1), pinching: pinching) { factor in
            // Pinch events arrive faster than layout; build on the newest state.
            let viewport = viewport(width: laidOut.width)
            return zoomViewport(viewport, to: viewport.pixelsPerSecond * CGFloat(factor), keeping: viewport.seconds(atX: x), atX: x)
        }
        viewportModel.zoomBand = band
    }

    /// A vertical pinch: the layers of the area under the pointer grow or
    /// shrink, and no other area's do. Past the shortest or tallest layers
    /// the area stretches instead (`layerHeightBand`).
    func zoomLayerHeight(by factor: CGFloat, at pointer: CGPoint, pinching: Bool = true) {
        guard let kind = shownAreaLayout.shown.first(where: { geometryStore.areas[$0]?.contains(pointer) == true }) else { return }
        if viewportModel.layerHeightBandKind != kind { viewportModel.layerHeightBand = RubberBandZoom() }
        viewportModel.layerHeightBandKind = kind
        let area = geometryStore.areas[kind] ?? .zero
        let anchor = area.height > 0 ? (pointer.y - area.minY) / area.height : 0.5
        var band = viewportModel.layerHeightBand
        // Kept to one side until the pinch ends (`commitLiveAreaLayout`).
        band.zoom(by: Double(factor), about: anchor, pinching: pinching) { factor in
            var layout = liveAreaLayout ?? areaLayout
            let before = layout.layerHeight(kind)
            layout.setLayerHeight(kind, before * CGFloat(factor))
            liveAreaLayout = layout
            return Double(layout.layerHeight(kind) / before)
        }
        viewportModel.layerHeightBand = band
    }

    /// The zoom buttons and keys zoom about the playhead: it stays where
    /// it is on screen, or comes to the middle if it was out of view. Past
    /// a limit the tracks stretch and spring back.
    func zoomAroundPlayhead(by factor: CGFloat) {
        let viewport = currentViewport
        let (seconds, anchorX) = playheadAnchor(viewport)
        var band = viewportModel.zoomBand
        band.zoom(by: Double(factor), about: anchorX / max(viewport.width, 1), pinching: false) { factor in
            zoomViewport(currentViewport, to: currentViewport.pixelsPerSecond * CGFloat(factor), keeping: seconds, atX: anchorX)
        }
        viewportModel.zoomBand = band
    }

    /// The slider zooms about the playhead too, but stops at its ends.
    func zoomAroundPlayhead(to pixelsPerSecond: CGFloat) {
        let viewport = currentViewport
        let (seconds, anchorX) = playheadAnchor(viewport)
        apply(viewport.zoomed(to: pixelsPerSecond, keeping: seconds, atX: anchorX))
    }

    private func playheadAnchor(_ viewport: TimelineViewport) -> (seconds: Double, x: CGFloat) {
        let seconds = livePlayheadTime.seconds
        let x = viewport.x(atSeconds: seconds)
        return (seconds, (0...viewport.width).contains(x) ? x : viewport.width / 2)
    }

    /// Zooms `viewport` and returns the factor its limits allowed.
    private func zoomViewport(_ viewport: TimelineViewport, to pixelsPerSecond: CGFloat, keeping seconds: Double, atX x: CGFloat) -> Double {
        let zoom = viewport.zoomed(to: pixelsPerSecond, keeping: seconds, atX: x)
        apply(zoom)
        return Double((zoom.pixelsPerSecond ?? viewport.fitPixelsPerSecond) / viewport.pixelsPerSecond)
    }

    func apply(_ zoom: (pixelsPerSecond: CGFloat?, scrollX: CGFloat)) {
        viewportModel.zoomedPixelsPerSecond = zoom.pixelsPerSecond
        viewportModel.scrollX = zoom.pixelsPerSecond == nil ? 0 : zoom.scrollX
    }

    /// Scrolls the tracks sideways by `deltaX` points, as a trackpad or a
    /// wheel does. Past either end of the timeline they slide on and spring
    /// back (`scrollBand`).
    func scrollTracks(by deltaX: CGFloat, phase: ScrollInputPhase, width: CGFloat) {
        var band = viewportModel.scrollBand
        band.scroll(by: deltaX, phase: phase) { delta in
            let before = viewport(width: width).scrollX
            viewportModel.scrollX = before + delta
            return viewport(width: width).scrollX - before
        }
        viewportModel.scrollBand = band
    }

    /// Scrolls so `time` sits just inside the left edge: a page turn, as
    /// when playback runs off the right of the view.
    func page(to time: CMTime) {
        let viewport = currentViewport
        viewportModel.scrollX = CGFloat(time.seconds) * viewport.pixelsPerSecond - viewport.width * 0.05
    }

    /// Lets drags at the edges of the tracks scroll them (`TimelineAutoScroll`).
    func configureAutoScroll() {
        autoScroll.scrollBy = { distance in
            let before = currentViewport.scrollX
            viewportModel.scrollX = before + distance
            return currentViewport.scrollX - before
        }
        // The tracks start where the names column ends.
        autoScroll.trackSpan = {
            let start = geometryStore.namesColumn.maxX
            return start...(start + viewportModel.trackAreaWidth)
        }
        autoScroll.areaScrollers = areaScrollers
        autoScroll.areaAt = { pointer in
            shownAreaLayout.shown.first { geometryStore.areas[$0]?.contains(pointer) == true }
        }
    }

    /// Scrolls `time` to the middle of the view if it is out of view.
    func reveal(_ time: CMTime) {
        let viewport = currentViewport
        let x = viewport.x(atSeconds: time.seconds)
        guard x < 0 || x > viewport.width else { return }
        viewportModel.scrollX = CGFloat(time.seconds) * viewport.pixelsPerSecond - viewport.width / 2
    }

    /// Retiming a clip can change the timeline's length enormously (a
    /// crawling clip), and a fitted view would rescale to match. Time edits
    /// pin the zoom the view had instead, until Fit is chosen.
    func keepZoomThroughRetiming(from old: TimingKey, to new: TimingKey) {
        guard viewportModel.zoomedPixelsPerSecond == nil, old.timelineID == new.timelineID, old.duration != new.duration,
              old.clipTimes != new.clipTimes
        else { return }
        viewportModel.zoomedPixelsPerSecond = TimelineViewport(
            durationSeconds: old.duration.seconds,
            frameRate: old.frameRate,
            width: viewportModel.trackAreaWidth,
            requestedPixelsPerSecond: nil,
            requestedScrollX: 0
        ).pixelsPerSecond
    }

    /// What `keepZoomThroughRetiming` compares: the timeline's length and
    /// frame rate, which set the fitted zoom, and its clips' times, so a
    /// length changed by a section alone doesn't pin the zoom.
    struct TimingKey: Equatable {
        var timelineID: UUID
        var duration: CMTime
        var frameRate: Double
        var clipTimes: [UUID: ClipTime]

        init(_ timeline: Timeline) {
            timelineID = timeline.id
            duration = timeline.duration
            frameRate = timeline.frameRate
            clipTimes = Dictionary(timeline.layers.flatMap(\.clips).map { ($0.id, $0.time) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// What decides whether to fit the timeline to a song dragged in: the
    /// clip, when a music clip is the only one on the timeline, and how
    /// many clips there are.
    struct SoleMusic: Equatable {
        var clipID: UUID?
        var clipCount: Int
    }

    var soleMusic: SoleMusic {
        let clips = timeline.layers.flatMap { layer in layer.clips.map { (layer.kind, $0.id) } }
        let sole = clips.count == 1 && clips[0].0 == .music ? clips[0].1 : nil
        return SoleMusic(clipID: sole, clipCount: clips.count)
    }

    func fitToWindow() {
        viewportModel.zoomedPixelsPerSecond = nil
        viewportModel.scrollX = 0
    }

    var zoomFractionBinding: Binding<Double> {
        Binding(
            get: { currentViewport.zoomFraction },
            set: { zoomAroundPlayhead(to: currentViewport.pixelsPerSecond(atZoomFraction: $0)) }
        )
    }

    /// Only moves the playhead — per-clip selection and repositioning are
    /// owned by each clip block's own gesture in `LayerClipRow`, which sits
    /// above this and so claims clicks on clips first. The playhead lands
    /// on frames.
    func scrubGesture(in viewport: TimelineViewport) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in scrub(atX: value.location.x, in: viewport) }
            .onEnded { value in scrub(atX: value.location.x, in: viewport) }
    }

    /// The same for views laid out across the whole span, whose x is in
    /// unscrolled content coordinates.
    func scrub(atX x: CGFloat, in viewport: TimelineViewport) {
        let seconds = max(0, min(timeline.duration.seconds, viewport.seconds(atX: x)))
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        // With snapping on, the playhead snaps to clip edges and beat markers.
        let snapped = snapping
            ? project.snapTargets(in: timelineID, playhead: nil, markers: drawnBeats(viewport)).nearest(to: time, within: snapTolerance(viewport))
            : nil
        onScrub(timeline.snappedToFrame(snapped ?? time))
    }
}
