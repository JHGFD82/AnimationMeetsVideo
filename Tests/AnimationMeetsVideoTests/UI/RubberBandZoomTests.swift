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

@Suite struct RubberBandScrollTests {
    /// A scroll limited to 0...100 points, as a view would keep it.
    private struct Limited {
        var position: CGFloat = 0
        mutating func apply(_ delta: CGFloat) -> CGFloat {
            let before = position
            position = min(max(position + delta, 0), 100)
            return position - before
        }
    }

    @Test func scrollsWithinTheEdgesWithoutPushing() {
        var band = RubberBandScroll()
        var view = Limited()
        band.scroll(by: 40) { view.apply($0) }
        #expect(view.position == 40 && band.overscroll == 0 && band.settle == .resting)
    }

    @Test func pushesPastAnEdgeAgainstResistance() {
        var band = RubberBandScroll()
        var view = Limited(position: 90)
        band.scroll(by: 30) { view.apply($0) }
        #expect(view.position == 100 && band.overscroll == 20 && band.settle == .nudged)
        // Past the end the content moves back, by less than was pushed.
        let offset = band.offset(length: 300)
        #expect(offset < 0 && -offset < 20)
        var far = band
        far.scroll(by: 10_000) { view.apply($0) }
        // However hard it is pushed, it slides no more than its reach.
        #expect(-far.offset(length: 300) <= 300 * RubberBandScroll.reach)
        #expect(-far.offset(length: 5000) <= RubberBandScroll.largestReach)
        // Before the start it moves the other way.
        var start = RubberBandScroll()
        var atStart = Limited()
        start.scroll(by: -10) { atStart.apply($0) }
        #expect(start.offset(length: 300) > 0)
    }

    @Test func scrollingBackTakesUpThePushFirst() {
        var band = RubberBandScroll()
        var view = Limited(position: 100)
        band.scroll(by: 20) { view.apply($0) }
        band.scroll(by: -15) { view.apply($0) }
        #expect(view.position == 100 && band.overscroll == 5)
        band.scroll(by: -25) { view.apply($0) }
        #expect(band.overscroll == 0 && view.position == 80)
        band.release()
        #expect(band.settle == .resting)
    }

    @Test func touchingHoldsAndLiftingLetsGoAtOnce() {
        var band = RubberBandScroll()
        var view = Limited(position: 100)
        band.scroll(by: 20, phase: .touching) { view.apply($0) }
        #expect(band.settle == .held)
        band.scroll(by: 0, phase: .lifted) { view.apply($0) }
        #expect(band.settle == .lifted)
        // The glide after the lift doesn't push it out again.
        band.release()
        band.scroll(by: 30, phase: .momentum) { view.apply($0) }
        #expect(band.overscroll == 0)
    }

    @Test func aGlideReachingTheEdgeBouncesOnceAndAtOnce() {
        var band = RubberBandScroll()
        var view = Limited(position: 95)
        band.scroll(by: 15, phase: .momentum) { view.apply($0) }
        #expect(view.position == 100 && band.overscroll == 10 && band.settle == .lifted)
        band.release()
        band.scroll(by: 15, phase: .momentum) { view.apply($0) }
        #expect(band.overscroll == 0)
        // A new touch starts afresh.
        band.scroll(by: 5, phase: .touching) { view.apply($0) }
        #expect(band.overscroll == 5 && band.settle == .held)
    }
}
