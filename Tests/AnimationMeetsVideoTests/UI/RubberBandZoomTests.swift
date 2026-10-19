import CoreGraphics
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct RubberBandZoomTests {
    /// A zoom limited to 1...4, as a view would keep it.
    private struct Limited {
        var zoom = 1.0
        mutating func apply(_ factor: Double) -> Double {
            let before = zoom
            zoom = min(max(zoom * factor, 1), 4)
            return zoom / before
        }
    }

    @Test func zoomsWithinTheLimitsWithoutStretching() {
        var band = RubberBandZoom()
        var view = Limited()
        band.zoom(by: 2, about: 0.5, pinching: true) { view.apply($0) }
        #expect(view.zoom == 2)
        #expect(band.stretch == 0)
        #expect(band.scale == 1)
        #expect(band.settle == .resting)
    }

    @Test func stretchesWhatALimitHoldsBack() {
        var band = RubberBandZoom()
        var view = Limited()
        band.zoom(by: 0.5, about: 0.25, pinching: true) { view.apply($0) }
        #expect(view.zoom == 1)
        #expect(abs(band.stretch - log(0.5)) < 1e-9)
        #expect(band.scale < 1)
        #expect(band.anchor == 0.25)
        #expect(band.settle == .held)

        var inward = RubberBandZoom()
        var closest = Limited(zoom: 4)
        inward.zoom(by: 2, about: 0.5, pinching: false) { closest.apply($0) }
        #expect(inward.scale > 1)
        #expect(inward.settle == .nudged)
    }

    @Test func splitsAZoomThatCrossesALimit() {
        var band = RubberBandZoom()
        var view = Limited(zoom: 2)
        band.zoom(by: 4, about: 0.5, pinching: true) { view.apply($0) }
        #expect(view.zoom == 4)
        #expect(abs(band.stretch - log(2)) < 1e-9)
    }

    @Test func zoomingBackTakesUpTheStretchFirst() {
        var band = RubberBandZoom()
        var view = Limited(zoom: 4)
        band.zoom(by: 4, about: 0.5, pinching: true) { view.apply($0) }
        band.zoom(by: 0.5, about: 0.5, pinching: true) { view.apply($0) }
        #expect(view.zoom == 4)
        #expect(abs(band.stretch - log(2)) < 1e-9)
        band.zoom(by: 0.25, about: 0.5, pinching: true) { view.apply($0) }
        #expect(band.stretch == 0)
        #expect(abs(view.zoom - 2) < 1e-9)
    }

    @Test func resistsMoreTheFurtherItGoes() {
        var near = RubberBandZoom(), far = RubberBandZoom()
        var a = Limited(), b = Limited()
        near.zoom(by: 0.5, about: 0.5, pinching: true) { a.apply($0) }
        far.zoom(by: 0.01, about: 0.5, pinching: true) { b.apply($0) }
        #expect(far.scale < near.scale)
        #expect(far.scale >= CGFloat(1 - RubberBandZoom.reach))
    }

    @Test func liftingAPinchLetsGo() {
        var band = RubberBandZoom()
        var view = Limited()
        band.zoom(by: 0.5, about: 0.5, pinching: true) { view.apply($0) }
        band.endPinch()
        #expect(band.settle == .lifted)
        band.release()
        #expect(band.stretch == 0)
        #expect(band.settle == .resting)
    }
}
