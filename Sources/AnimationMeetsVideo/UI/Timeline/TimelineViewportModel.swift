import CoreMedia
import SwiftUI

/// What changes as the timeline is scrolled and zoomed, many times a
/// second: kept out of `TimelineView`'s own state so that only the views
/// that draw the tracks (`TimelineTrackSurface` and the views it hands the
/// viewport to) follow it, and the header and the rest of `TimelineView`
/// aren't built again for each step of a scroll, a pinch or a bounce.
@MainActor
@Observable
final class TimelineViewportModel {
    var scrollX: CGFloat = 0
    /// The chosen zoom, or nil while the whole timeline is fitted to the
    /// window. Kept in points per second, not relative to the fit, so
    /// moving a clip past the end doesn't rescale everything.
    var zoomedPixelsPerSecond: CGFloat?
    /// The time zoom's edge: a zoom past the fit or the closest stretches
    /// the tracks and springs back.
    var zoomBand = RubberBandZoom()
    /// The sideways scroll's edge: past the start or end of the timeline
    /// the tracks slide on and spring back. Time zooms, so it bounces;
    /// the areas scroll up and down in system scroll views, which do too.
    var scrollBand = RubberBandScroll()
    /// The same for a vertical pinch's layer height, in the area it pinched.
    var layerHeightBand = RubberBandZoom()
    var layerHeightBandKind: LayerKind?
    /// Where a drag in progress snapped, drawn as a line across the layers.
    var snapIndicator: CMTime?
    var trackAreaWidth: CGFloat = 800

    func viewport(durationSeconds: Double, frameRate: Double, width: CGFloat) -> TimelineViewport {
        TimelineViewport(
            durationSeconds: durationSeconds,
            frameRate: frameRate,
            width: width,
            requestedPixelsPerSecond: zoomedPixelsPerSecond,
            requestedScrollX: scrollX
        )
    }

    /// Back to the whole timeline fitted, as for another timeline.
    func reset() {
        zoomedPixelsPerSecond = nil
        scrollX = 0
        snapIndicator = nil
    }
}
