import CoreGraphics
import Foundation

/// Where the timeline's frame sits in a viewer's well, and the way between
/// the frame's pixels and the well's points (see docs/viewer-handles.md,
/// "Zooming and scrolling the viewer"). Frame pixels have their origin at
/// the frame's top left and y down; view points at the well's top left.
///
/// The viewer starts at **Fit**: the frame fitted to the well inside its
/// margin and centered. A zoom (1 is 100%, a timeline pixel to a pixel of
/// the screen) and a place (the frame pixel at the middle of the well)
/// change what is looked at, never the project.
struct ViewerMapping: Equatable {
    var frameSize: CGSize
    var wellSize: CGSize
    /// Screen pixels per point, for 100% to be a pixel for a pixel.
    var backingScale: Double = 2
    /// Around the frame at Fit, in points: 36 in the main viewer, none on
    /// the external display, which fills its screen.
    var fitMargin: Double = 36
    /// Nil for Fit.
    var zoom: Double?
    /// The frame pixel at the middle of the well; nil for the frame's
    /// middle, centered.
    var center: CGPoint?

    static let zoomSteps: [Double] = [0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 4, 8]
    static let zoomRange: ClosedRange<Double> = 0.1...8
    /// How much of the frame stays in the well on each axis, in points,
    /// however far it is scrolled.
    static let keptInView = 48.0

    // MARK: Zoom

    /// The zoom Fit gives.
    var fitZoom: Double {
        guard frameSize.width > 0, frameSize.height > 0 else { return 1 }
        let width = max(Double(wellSize.width) - 2 * fitMargin, 1)
        let height = max(Double(wellSize.height) - 2 * fitMargin, 1)
        return min(width / Double(frameSize.width), height / Double(frameSize.height)) * backingScale
    }

    /// The zoom shown: the one set, or Fit's.
    var effectiveZoom: Double { zoom ?? fitZoom }

    var isFit: Bool { zoom == nil }

    /// View points per frame pixel.
    var pointsPerPixel: Double { effectiveZoom / max(backingScale, 0.01) }

    /// Frame pixels per view point, which a handle's size in points is
    /// measured with.
    var pixelsPerPoint: Double { 1 / max(pointsPerPixel, 1e-9) }

    /// The zoom as the Fit chip shows it: "64%".
    var zoomText: String {
        HandleFormat.number(effectiveZoom * 100, digits: effectiveZoom < 0.1 ? 1 : 0) + "%"
    }

    // MARK: Place

    var frameMiddle: CGPoint { CGPoint(x: frameSize.width / 2, y: frameSize.height / 2) }
    var wellMiddle: CGPoint { CGPoint(x: wellSize.width / 2, y: wellSize.height / 2) }

    /// The frame pixel at the middle of the well.
    var effectiveCenter: CGPoint { center ?? frameMiddle }

    /// Whether the frame's middle is at the well's middle, to half a point.
    var isCentered: Bool {
        let c = effectiveCenter
        let ppp = pointsPerPixel
        return abs(Double(c.x - frameMiddle.x)) * ppp < 0.5 && abs(Double(c.y - frameMiddle.y)) * ppp < 0.5
    }

    // MARK: Mapping

    func toView(_ point: CGPoint) -> CGPoint {
        let ppp = CGFloat(pointsPerPixel), c = effectiveCenter, m = wellMiddle
        return CGPoint(x: m.x + (point.x - c.x) * ppp, y: m.y + (point.y - c.y) * ppp)
    }

    func toFrame(_ point: CGPoint) -> CGPoint {
        let ppp = CGFloat(pointsPerPixel), c = effectiveCenter, m = wellMiddle
        return CGPoint(x: c.x + (point.x - m.x) / ppp, y: c.y + (point.y - m.y) / ppp)
    }

    /// Where the picture is drawn in the well, in points.
    var pictureRect: CGRect {
        let origin = toView(.zero)
        let ppp = CGFloat(pointsPerPixel)
        return CGRect(x: origin.x, y: origin.y, width: frameSize.width * ppp, height: frameSize.height * ppp)
    }

    // MARK: Changes

    /// Zoomed by `factor` about `point` in the well: the spot of the
    /// picture under it stays under it.
    func zoomed(by factor: Double, about point: CGPoint) -> ViewerMapping {
        zoomed(to: effectiveZoom * factor, about: point)
    }

    /// At `zoom` (limited to 10% to 800%), about `point` in the well.
    func zoomed(to zoom: Double, about point: CGPoint) -> ViewerMapping {
        let spot = toFrame(point)
        var next = self
        next.zoom = zoom.clamped(between: Self.zoomRange.lowerBound, and: Self.zoomRange.upperBound)
        let ppp = CGFloat(next.pointsPerPixel)
        next.center = CGPoint(x: spot.x - (point.x - wellMiddle.x) / ppp, y: spot.y - (point.y - wellMiddle.y) / ppp)
        return next.keptInView()
    }

    /// One of `zoomSteps` up (⌘+), about the middle of the well.
    func zoomedIn() -> ViewerMapping {
        let current = effectiveZoom
        let next = Self.zoomSteps.first { $0 > current * 1.0001 } ?? Self.zoomRange.upperBound
        return zoomed(to: next, about: wellMiddle)
    }

    /// One of `zoomSteps` down (⌘−), about the middle of the well.
    func zoomedOut() -> ViewerMapping {
        let current = effectiveZoom
        let next = Self.zoomSteps.last { $0 < current * 0.9999 } ?? Self.zoomRange.lowerBound
        return zoomed(to: next, about: wellMiddle)
    }

    /// The picture moved by `delta` points, as a scroll moves it.
    func scrolled(by delta: CGVector) -> ViewerMapping {
        var next = self
        let ppp = CGFloat(pointsPerPixel), c = effectiveCenter
        next.center = CGPoint(x: c.x - delta.dx / ppp, y: c.y - delta.dy / ppp)
        return next.keptInView()
    }

    /// Fit, centered (⌘0).
    func fitted() -> ViewerMapping {
        var next = self
        next.zoom = nil
        next.center = nil
        return next
    }

    /// Centered, keeping the zoom (⇧⌘0).
    func centered() -> ViewerMapping {
        var next = self
        next.center = nil
        return next
    }

    /// The place limited so at least `keptInView` points of the frame (or
    /// all of it, when it is smaller) stay in the well on each axis.
    func keptInView() -> ViewerMapping {
        guard let center else { return self }
        var next = self
        let ppp = pointsPerPixel
        func limit(_ c: CGFloat, frame: CGFloat, well: CGFloat) -> CGFloat {
            let kept = min(Self.keptInView, Double(frame) * ppp, Double(well))
            let reach = (Double(well) / 2 - kept) / ppp
            let low = -reach, high = Double(frame) + reach
            guard low <= high else { return frame / 2 }
            return CGFloat(Double(c).clamped(between: low, and: high))
        }
        next.center = CGPoint(
            x: limit(center.x, frame: frameSize.width, well: wellSize.width),
            y: limit(center.y, frame: frameSize.height, well: wellSize.height)
        )
        return next
    }
}
