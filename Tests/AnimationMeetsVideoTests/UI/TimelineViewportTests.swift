import CoreGraphics
import Testing
@testable import AnimationMeetsVideo

@Suite struct TimelineViewportTests {
    private func viewport(pixelsPerSecond: CGFloat? = nil, scrollX: CGFloat = 0) -> TimelineViewport {
        TimelineViewport(durationSeconds: 60, frameRate: 24, width: 600, requestedPixelsPerSecond: pixelsPerSecond, requestedScrollX: scrollX)
    }

    @Test func fitsTheTimelineWithRoomAfterItsEnd() {
        let fitted = viewport()
        #expect(fitted.contentSeconds == 63)
        #expect(abs(fitted.contentWidth - 600) < 0.001)
        #expect(fitted.isFitted)
        #expect(fitted.scrollX == 0)
    }

    @Test func clampsZoomAndScroll() {
        #expect(viewport(pixelsPerSecond: 1).isFitted)
        #expect(viewport(pixelsPerSecond: 1_000_000).pixelsPerSecond == 24 * TimelineViewport.maximumFrameWidth)
        let zoomed = viewport(pixelsPerSecond: 100, scrollX: 99_999)
        #expect(abs(zoomed.scrollX - (6300 - 600)) < 0.001)
        #expect(viewport(pixelsPerSecond: 100, scrollX: -50).scrollX == 0)
    }

    @Test func zoomKeepsTheAnchorInPlace() {
        let start = viewport(pixelsPerSecond: 50, scrollX: 400)
        let anchorX: CGFloat = 230
        let seconds = start.seconds(atX: anchorX)
        let zoom = start.zoomed(to: 200, keeping: seconds, atX: anchorX)
        let after = viewport(pixelsPerSecond: zoom.pixelsPerSecond, scrollX: zoom.scrollX)
        #expect(abs(after.x(atSeconds: seconds) - anchorX) < 0.001)
    }

    @Test func zoomingOutToTheFitReturnsNil() {
        let start = viewport(pixelsPerSecond: 50, scrollX: 400)
        #expect(start.zoomed(to: 0.1, keeping: 10, atX: 0).pixelsPerSecond == nil)
    }

    @Test func zoomFractionRoundTrips() {
        let start = viewport(pixelsPerSecond: 120)
        let fraction = start.zoomFraction
        #expect(abs(start.pixelsPerSecond(atZoomFraction: fraction) - 120) < 0.001)
        #expect(viewport().zoomFraction == 0)
    }

    @Test func fittingASpanCentersItWithinTheMargin() {
        let fit = viewport().fitting(20, 24, margin: 0.1)
        let after = viewport(pixelsPerSecond: fit.pixelsPerSecond, scrollX: fit.scrollX)
        #expect(abs(after.x(atSeconds: 20) - 60) < 0.001)
        #expect(abs(after.x(atSeconds: 24) - 540) < 0.001)
    }

    @Test func fittingAShortSpanCentersItAtTheClosestZoom() {
        let fit = viewport().fitting(30, 30.001, margin: 0.1)
        #expect(fit.pixelsPerSecond == 24 * TimelineViewport.maximumFrameWidth)
        let after = viewport(pixelsPerSecond: fit.pixelsPerSecond, scrollX: fit.scrollX)
        #expect(abs(after.x(atSeconds: 30.0005) - 300) < 0.001)
    }

    @Test func fittingALongSpanGetsTheFit() {
        #expect(viewport().fitting(0, 60, margin: 0.1).pixelsPerSecond == nil)
    }
}
