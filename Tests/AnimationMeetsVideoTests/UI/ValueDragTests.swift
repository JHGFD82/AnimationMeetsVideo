import AppKit
import SwiftUI
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

    @Test func theModifierHeldFirstSetsThePaceAndTheOtherIsIgnored() {
        var pace = DragPace()
        #expect(pace.resolve([]) == [])

        // Option first: a Shift pressed meanwhile changes nothing.
        #expect(pace.resolve(.option) == .option)
        #expect(pace.resolve([.option, .shift]) == .option)
        #expect(pace.resolve(.option) == .option)
        #expect(pace.resolve([]) == [])

        // Shift first: an Option pressed meanwhile changes nothing.
        #expect(pace.resolve(.shift) == .shift)
        #expect(pace.resolve([.option, .shift]) == .shift)
        #expect(pace.resolve([]) == [])

        // Both at once: Shift, as before.
        #expect(pace.resolve([.option, .shift]) == .shift)
    }

    @Test func theOtherModifierTakesOverOnceTheFirstIsLetGo() {
        var pace = DragPace()
        _ = pace.resolve(.option)
        _ = pace.resolve([.option, .shift])
        #expect(pace.resolve(.shift) == .shift)
        #expect(pace.resolve([]) == [])
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

/// A number keeps the widest it has been shown, so a decimal point added by
/// a drag doesn't resize its row, and taking it away doesn't again.
@MainActor
struct NumberWidthTests {
    @Test func aNumberDoesNotNarrowAfterWidening() {
        func field(_ value: Double) -> some View {
            NumericField(value: value, fractionDigits: 1) { _ in }
        }
        let host = NSHostingView(rootView: field(100))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func width() -> CGFloat {
            for _ in 0..<4 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
            }
            return host.fittingSize.width
        }
        let whole = width()
        host.rootView = field(100.5)
        let wider = width()
        #expect(wider > whole)
        host.rootView = field(100)
        #expect(width() == wider)
    }
}
