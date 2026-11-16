import CoreGraphics
import Foundation

/// The pointer a turn follows (see docs/viewer-handles.md, "Turning"):
/// while a rotation zone is dragged the system pointer is hidden and held
/// still, and the mouse's movement is added up here instead, so the drag
/// can go on past the well's and the screen's edges. The farther it goes
/// from the anchor, the less each point of movement turns the picture,
/// which is how a turn gets fine.
struct FreePointer: Equatable, Sendable {
    /// Where the drag has got to, in view points; anywhere, off the well
    /// included.
    private(set) var location: CGPoint
    /// Where the system pointer was when the drag took it, in view points.
    let grabbed: CGPoint

    init(at point: CGPoint) {
        location = point
        grabbed = point
    }

    /// The mouse moved by `dx`, `dy` points (y down, as `NSEvent` gives
    /// its deltas).
    mutating func move(dx: Double, dy: Double) {
        location.x += dx
        location.y += dy
    }

    /// Where to show the system pointer again as the drag ends: on the
    /// line from `pivot` through the drag's point, as far from `pivot` as
    /// it was grabbed, which is about where the rotation zone it was
    /// grabbed in has turned to. Where the drag ended at the pivot itself,
    /// where it was grabbed.
    func letGo(about pivot: CGPoint) -> CGPoint {
        let dx = Double(location.x - pivot.x), dy = Double(location.y - pivot.y)
        let reach = hypot(dx, dy)
        guard reach > 1e-6 else { return grabbed }
        let radius = Double(hypot(grabbed.x - pivot.x, grabbed.y - pivot.y))
        return CGPoint(x: Double(pivot.x) + dx / reach * radius, y: Double(pivot.y) + dy / reach * radius)
    }
}
