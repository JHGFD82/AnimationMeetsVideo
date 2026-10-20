import AppKit
import Testing
@testable import AnimationMeetsVideo

@Suite struct ValueDragTests {
    @Test func aValueMovesByTheStepForEachPointAndShiftAndOptionScaleIt() {
        #expect(ValueDrag.value(from: 10, distance: 5, step: 2, flags: [], range: nil) == 20)
        #expect(ValueDrag.value(from: 10, distance: 5, step: 2, flags: .shift, range: nil) == 110)
        #expect(ValueDrag.value(from: 10, distance: 5, step: 2, flags: .option, range: nil) == 11)
    }

    @Test func aValueStaysInItsRange() {
        #expect(ValueDrag.value(from: 10, distance: 500, step: 1, flags: [], range: 0...100) == 100)
        #expect(ValueDrag.value(from: 10, distance: -500, step: 1, flags: [], range: 0...100) == 0)
    }

    /// Escape ends a drag while the button is still down, and the gesture
    /// goes on reporting moves: those must not begin another drag.
    @Test func aPressCancelledByEscapeBeginsNoDragUntilTheButtonIsReleased() {
        var press = ValueDragPress()
        #expect(press.mayBegin)

        press.cancel()
        #expect(!press.mayBegin)
        // Moves that follow, with the button down.
        #expect(!press.mayBegin)

        press.release()
        #expect(press.mayBegin)
    }
}
