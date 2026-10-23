import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ZoomScaleTests {
    @Test func slidersAreEvenInRatio() {
        let range = 1.0...100
        #expect(ZoomScale.fraction(of: 1, in: range) == 0)
        #expect(abs(ZoomScale.fraction(of: 10, in: range) - 0.5) < 1e-12)
        #expect(ZoomScale.fraction(of: 100, in: range) == 1)
        #expect(abs(ZoomScale.zoom(atFraction: 0.5, in: range) - 10) < 1e-9)
    }

    @Test func aPlaceRoundTripsThroughItsZoom() {
        let range = 0.25...1000.0
        for fraction in stride(from: 0.0, through: 1, by: 0.125) {
            let zoom = ZoomScale.zoom(atFraction: fraction, in: range)
            #expect(abs(ZoomScale.fraction(of: zoom, in: range) - fraction) < 1e-12)
        }
    }

    @Test func theFactorReachesThePlace() {
        let range = 1.0...16
        let factor = ZoomScale.factor(from: 2, toFraction: 0.75, in: range)
        #expect(abs(2 * factor - 8) < 1e-9)
    }

    @Test func zoomsPastTheEndsSitAtThem() {
        #expect(ZoomScale.fraction(of: 0.5, in: 1...4) == 0)
        #expect(ZoomScale.fraction(of: 9, in: 1...4) == 1)
    }

    /// A song too short to zoom, say: the slider stays at the start.
    @Test func anEmptyRangeHasOnePlace() {
        #expect(ZoomScale.fraction(of: 3, in: 3...3) == 0)
        #expect(ZoomScale.zoom(atFraction: 0.7, in: 3...3) == 3)
    }

    /// The graph editor's time slider runs from the whole span to a few
    /// frames, as its pinch does.
    @Test func graphTimeZoomsSpanTheClipToAFewFrames() {
        let zooms = KeyframeGraphViewport.timeZooms(span: 0...10, frame: 0.1)
        #expect(zooms.lowerBound == 1)
        #expect(abs(zooms.upperBound - 10 / (KeyframeGraphViewport.fewestFrames * 0.1)) < 1e-9)

        var viewport = KeyframeGraphViewport()
        #expect(viewport.timeZoom(fit: 0...10, span: 0...10) == 1)
        viewport.zoomTimes(by: 4, around: 5, fit: 0...10, span: 0...10, frame: 0.1)
        #expect(abs(viewport.timeZoom(fit: 0...10, span: 0...10) - 4) < 1e-9)
    }
}
