import CoreGraphics
import Testing
@testable import AnimationMeetsVideo

@Suite struct EffectStackDropTests {
    /// Three rows of 20 points, from 10 down.
    private let rows = [
        CGRect(x: 0, y: 10, width: 100, height: 20),
        CGRect(x: 0, y: 30, width: 100, height: 20),
        CGRect(x: 0, y: 50, width: 100, height: 20),
    ]

    @Test func goesBeforeTheRowWhoseMiddleIsBelowThePointer() {
        let above = EffectStackDropDelegate.place(15, among: rows)
        #expect(above.index == 0 && above.line == 10)
        // Past the first row's middle: between the first and the second.
        let between = EffectStackDropDelegate.place(25, among: rows)
        #expect(between.index == 1 && between.line == 30)
    }

    @Test func goesAfterTheLastRowBelowItsMiddle() {
        let after = EffectStackDropDelegate.place(65, among: rows)
        #expect(after.index == 3 && after.line == 70)
    }

    @Test func anEmptyStackHasNoLine() {
        let empty = EffectStackDropDelegate.place(10, among: [])
        #expect(empty.index == 0 && empty.line == nil)
    }
}
