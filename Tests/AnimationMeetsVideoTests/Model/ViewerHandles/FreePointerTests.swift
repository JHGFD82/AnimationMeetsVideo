import CoreGraphics
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A turn's unbounded pointer (`FreePointer`) and where it shows the
/// system pointer again.
@Suite struct FreePointerTests {
    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9
    }

    @Test func itAddsUpTheMouseMovementWithoutBounds() {
        var free = FreePointer(at: CGPoint(x: 10, y: 20))
        free.move(dx: 5000, dy: -3)
        free.move(dx: 1, dy: 4)
        #expect(close(free.location, CGPoint(x: 5011, y: 21)))
        #expect(close(free.grabbed, CGPoint(x: 10, y: 20)))
    }

    @Test func thePointerComesBackAsFarFromThePivotAsItWasGrabbed() {
        // Grabbed 100 points right of the pivot; dragged far below it.
        var free = FreePointer(at: CGPoint(x: 100, y: 0))
        free.move(dx: -100, dy: 4000)
        let back = free.letGo(about: .zero)
        #expect(close(back, CGPoint(x: 0, y: 100)))
    }

    @Test func atThePivotItComesBackWhereItWasGrabbed() {
        var free = FreePointer(at: CGPoint(x: 30, y: 40))
        free.move(dx: -30, dy: -40)
        #expect(close(free.letGo(about: .zero), CGPoint(x: 30, y: 40)))
    }

    @Test func thePointerComesBackInsideTheWell() {
        let well = CGRect(x: 0, y: 0, width: 800, height: 450)
        #expect(close(FreePointer.kept(CGPoint(x: 5000, y: -300), within: well), CGPoint(x: 796, y: 4)))
        #expect(close(FreePointer.kept(CGPoint(x: 120, y: 200), within: well), CGPoint(x: 120, y: 200)))
    }

    @Test func fartherFromTheAnchorTheSameMovementTurnsLess() {
        let pivot = CGPoint.zero
        func turned(from distance: Double) -> Double {
            var drag = HandleDrag(handle: .rotate(.topRight), start: CGPoint(x: distance, y: 0))
            drag.move(to: CGPoint(x: distance, y: 10), about: pivot, holdingWithin: 10)
            return drag.swept
        }
        #expect(turned(from: 2000) < turned(from: 200) / 5)
    }
}
