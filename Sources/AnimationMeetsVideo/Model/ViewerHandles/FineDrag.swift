import CoreGraphics
import Foundation

/// The loupe's slowed pointer (see docs/viewer-handles.md, "The loupe"):
/// a handle pressed and held still opens a magnified view of where it is,
/// and the drag then counts the pointer's movement at a fraction, a
/// quarter, or a sixteenth while Option is held. The rate changes at the
/// point the pointer is at when Option goes down or up, so the handle
/// never jumps.
struct FineDrag: Equatable, Sendable {
    /// How much the loupe enlarges, and how much slower the drag goes in it.
    static let magnification = 4.0
    /// How much slower again with Option.
    static let finer = 4.0
    /// How long a press must hold still on a handle before the loupe opens.
    static let holdDelay = Duration.milliseconds(450)

    /// Where the pointer was, in view points, when the rate last changed,
    /// and where the drag had got to then.
    private(set) var pointerOrigin: CGPoint
    private(set) var effectiveOrigin: CGPoint
    private(set) var isFiner: Bool

    init(at point: CGPoint, finer: Bool = false) {
        pointerOrigin = point
        effectiveOrigin = point
        isFiner = finer
    }

    /// Pointer movement per point of the drag's.
    var slowing: Double { Self.magnification * (isFiner ? Self.finer : 1) }

    /// Where the drag is with the pointer at `pointer`.
    func effective(_ pointer: CGPoint) -> CGPoint {
        let slowing = CGFloat(slowing)
        return CGPoint(
            x: effectiveOrigin.x + (pointer.x - pointerOrigin.x) / slowing,
            y: effectiveOrigin.y + (pointer.y - pointerOrigin.y) / slowing
        )
    }

    /// Option went down or up with the pointer at `pointer`.
    mutating func setFiner(_ finer: Bool, pointer: CGPoint) {
        guard finer != isFiner else { return }
        effectiveOrigin = effective(pointer)
        pointerOrigin = pointer
        isFiner = finer
    }
}
