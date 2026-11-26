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

    /// The tracks at width 450 once the 150-point names column takes 150
    /// more.
    private func narrowed(to zoom: (pixelsPerSecond: CGFloat?, scrollX: CGFloat, leadIn: CGFloat)) -> TimelineViewport {
        TimelineViewport(
            durationSeconds: 60, frameRate: 24, width: 450, requestedPixelsPerSecond: zoom.pixelsPerSecond, requestedScrollX: zoom.scrollX,
            leadIn: zoom.leadIn
        )
    }

    /// The tracks at width 600 once the names column narrows from 300 to 150.
    private func widened(to zoom: (pixelsPerSecond: CGFloat?, scrollX: CGFloat, leadIn: CGFloat)) -> TimelineViewport {
        TimelineViewport(
            durationSeconds: 60, frameRate: 24, width: 600, requestedPixelsPerSecond: zoom.pixelsPerSecond, requestedScrollX: zoom.scrollX,
            leadIn: zoom.leadIn
        )
    }

    @Test func narrowingAtTheStartLeavesRoomBeforeItRatherThanMovingIt() {
        // Wide names column, tracks scrolled to the start.
        let wide = narrowed(to: (50, 0, 0))
        let seconds = wide.seconds(atX: 100)
        let kept = wide.keepingPlace(asLeftEdgeMovesBy: -150)
        #expect(kept.leadIn == 150)
        let after = widened(to: kept)
        #expect(after.scrollX == -150)
        // In the window, a moment is at the column's width plus its x.
        #expect(abs((150 + after.x(atSeconds: seconds)) - (300 + 100)) < 0.001)
        // No further than the lead-in.
        #expect(widened(to: (50, -400, 150)).scrollX == -150)
    }

    @MainActor @Test func scrollingPastTheStartLetsTheLeadInGo() {
        let model = TimelineViewportModel()
        model.zoomedPixelsPerSecond = 50
        model.scrollX = -150
        model.leadIn = 150
        model.scroll(to: -100)
        #expect(model.leadIn == 100)
        model.scroll(to: 50)
        #expect(model.leadIn == 0)
        #expect(model.viewport(durationSeconds: 60, frameRate: 24, width: 600).minScrollX == 0)
        model.leadIn = 150
        model.reset()
        #expect(model.leadIn == 0)
    }

    @Test func aFittedTimelineKeepsItsPlaceNarrowingAtTheStart() {
        // Fitted while narrow, widened (now a zoom), scrolled back to the
        // start, then narrowed: the fit's scale is kept, with room before
        // the start.
        let widenedFit = narrowed(to: viewport().keepingPlace(asLeftEdgeMovesBy: 150))
        let atStart = narrowed(to: (widenedFit.pixelsPerSecond, 0, 0))
        let kept = atStart.keepingPlace(asLeftEdgeMovesBy: -150)
        #expect(kept.pixelsPerSecond != nil)
        #expect(widened(to: kept).scrollX == -150)
    }

    @Test func aWideningNamesColumnLeavesEveryMomentInPlace() {
        // In the window, a moment is at the column's width plus its x.
        let zoomed = viewport(pixelsPerSecond: 50, scrollX: 400)
        let seconds = zoomed.seconds(atX: 230)
        let after = narrowed(to: zoomed.keepingPlace(asLeftEdgeMovesBy: 150))
        let moved = 300 + after.x(atSeconds: seconds) - (150 + 230)
        #expect(abs(moved) < 0.001)
    }

    @Test func aFittedTimelineComesBackToTheFitWhenTheColumnNarrowsAgain() {
        let fitted = viewport()
        let seconds = fitted.seconds(atX: 300)
        let widened = narrowed(to: fitted.keepingPlace(asLeftEdgeMovesBy: 150))
        let moved = 300 + widened.x(atSeconds: seconds) - (150 + 300)
        #expect(abs(moved) < 0.001)
        let back = widened.keepingPlace(asLeftEdgeMovesBy: -150)
        #expect(back.pixelsPerSecond == nil)
        #expect(back.scrollX == 0)
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
