import CoreGraphics
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ViewerMappingTests {
    private func close(_ a: CGPoint, _ b: CGPoint, within tolerance: Double = 0.001) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    private let wide = ViewerMapping(frameSize: CGSize(width: 1920, height: 1080), wellSize: CGSize(width: 1032, height: 1000), backingScale: 2)

    @Test func fitLetterboxesAWideFrameInsideTheMargin() {
        // 960 points across for 1920 pixels: half a point a pixel, 100% on
        // a screen of two pixels a point.
        #expect(abs(wide.pointsPerPixel - 0.5) < 1e-9)
        #expect(abs(wide.fitZoom - 1) < 1e-9)
        #expect(close(wide.pictureRect.origin, CGPoint(x: 36, y: 230)))
        #expect(close(wide.toView(CGPoint(x: 960, y: 540)), CGPoint(x: 516, y: 500)))
        #expect(close(wide.toFrame(CGPoint(x: 516, y: 500)), CGPoint(x: 960, y: 540)))
    }

    @Test func fitPillarboxesATallFrame() {
        let tall = ViewerMapping(frameSize: CGSize(width: 1080, height: 1920), wellSize: CGSize(width: 1000, height: 1032), backingScale: 1)
        #expect(abs(tall.pointsPerPixel - 0.5) < 1e-9)
        #expect(close(tall.pictureRect.origin, CGPoint(x: 230, y: 36)))
        #expect(tall.zoomText == "50%")
    }

    @Test func mappingRoundTripsWhenZoomedAndScrolled() {
        let moved = wide.zoomed(to: 2, about: CGPoint(x: 100, y: 700)).scrolled(by: CGVector(dx: 30, dy: -12))
        for point in [CGPoint.zero, CGPoint(x: 1920, y: 1080), CGPoint(x: 333, y: 777)] {
            #expect(close(moved.toFrame(moved.toView(point)), point))
        }
    }

    @Test func aPinchKeepsThePointUnderThePointer() {
        let pointer = CGPoint(x: 300, y: 420)
        let spot = wide.toFrame(pointer)
        let zoomed = wide.zoomed(by: 1.7, about: pointer)
        #expect(close(zoomed.toView(spot), pointer))
        #expect(!zoomed.isFit)
    }

    @Test func zoomIsLimitedToTenAndEightHundredPercent() {
        #expect(wide.zoomed(to: 50, about: .zero).effectiveZoom == 8)
        #expect(wide.zoomed(to: 0.001, about: .zero).effectiveZoom == 0.1)
    }

    @Test func zoomStepsGoThroughTheSizes() {
        var mapping = wide.zoomed(to: 0.6, about: wide.wellMiddle)
        mapping = mapping.zoomedIn()
        #expect(mapping.effectiveZoom == 0.75)
        mapping = mapping.zoomedIn()
        #expect(mapping.effectiveZoom == 1)
        mapping = mapping.zoomedOut().zoomedOut()
        #expect(mapping.effectiveZoom == 0.5)
        #expect(wide.zoomed(to: 8, about: .zero).zoomedIn().effectiveZoom == 8)
    }

    @Test func thePictureCantBeScrolledAway() {
        let far = wide.zoomed(to: 1, about: wide.wellMiddle).scrolled(by: CGVector(dx: 100_000, dy: -100_000))
        let picture = far.pictureRect
        #expect(abs(picture.minX - (1032 - 48)) < 0.01)
        #expect(abs(picture.maxY - 48) < 0.01)
    }

    @Test func fitAndCenter() {
        let moved = wide.zoomed(to: 2, about: CGPoint(x: 10, y: 10))
        #expect(!moved.isCentered)
        let centered = moved.centered()
        #expect(centered.isCentered && centered.effectiveZoom == 2)
        let fitted = moved.fitted()
        #expect(fitted.isFit && fitted.isCentered && fitted == wide)
    }

    @Test func handlesKeepTheirSizeInPoints() {
        let zoomed = wide.zoomed(to: 4, about: wide.wellMiddle)
        #expect(abs(zoomed.pixelsPerPoint - 0.5) < 1e-9)
        #expect(abs(wide.pixelsPerPoint - 2) < 1e-9)
    }
}
