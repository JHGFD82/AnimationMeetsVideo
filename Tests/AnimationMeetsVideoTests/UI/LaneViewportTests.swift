import CoreGraphics
import Testing
@testable import AnimationMeetsVideo

/// How the effects panel's lanes zoom and scroll beside the controls.
@MainActor
struct LaneViewportTests {
    private func viewport() -> LaneViewport {
        let viewport = LaneViewport()
        viewport.fit(width: 400, maxZoom: 10)
        return viewport
    }

    @Test func zoomingInKeepsThePointUnderTheCursorWhereItWas() {
        let viewport = viewport()
        viewport.zoom(by: 2, aboutX: 100, pinching: false)
        #expect(viewport.zoom == 2)
        // Content x 100 was under the cursor at 100, and still is.
        #expect(viewport.scrollX == 100)
    }

    @Test func zoomingOutPastTheWholeClipStopsAtItAndStretches() {
        let viewport = viewport()
        viewport.zoom(by: 0.5, aboutX: 200, pinching: true)
        #expect(viewport.zoom == 1)
        #expect(viewport.scrollX == 0)
        #expect(viewport.zoomBand.stretch < 0)
    }

    @Test func zoomingInPastTheClosestStopsAtItAndStretches() {
        let viewport = viewport()
        viewport.zoom(by: 100, aboutX: 0, pinching: true)
        #expect(viewport.zoom == 10)
        #expect(viewport.zoomBand.stretch > 0)
    }

    @Test func scrollingStaysWithinTheLanesAndBouncesPastTheEnds() {
        let viewport = viewport()
        viewport.zoom(by: 2, aboutX: 0, pinching: false)
        viewport.scroll(by: 5000, phase: .wheel)
        #expect(viewport.scrollX == viewport.maxScrollX)
        #expect(viewport.maxScrollX == 400)
        #expect(viewport.scrollBand.overscroll > 0)
        viewport.scroll(by: -5000, phase: .wheel)
        #expect(viewport.scrollX == 0)
    }

    @Test func aNarrowerWindowKeepsTheScrollInRange() {
        let viewport = viewport()
        viewport.zoom(by: 4, aboutX: 0, pinching: false)
        viewport.scroll(by: 1200, phase: .wheel)
        viewport.fit(width: 200, maxZoom: 2)
        #expect(viewport.zoom == 2)
        #expect(viewport.scrollX <= viewport.maxScrollX)
    }
}
