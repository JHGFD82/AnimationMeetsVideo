import AppKit
import Testing
@testable import AnimationMeetsVideo

/// The one way of picking several things, shared by the editors.
@Suite struct SelectionSetTests {
    private let order = ["a", "b", "c", "d", "e"]

    @Test func modifiersChooseWhatAClickDoes() {
        #expect(SelectClick([]) == .only)
        #expect(SelectClick(.command) == .toggle)
        #expect(SelectClick(.shift) == .extend)
        #expect(SelectClick([.command, .shift]) == .toggle)
        #expect(SelectClick.lassoAdds(.shift))
        #expect(SelectClick.lassoAdds(.command))
        #expect(!SelectClick.lassoAdds(.option))
    }

    @Test func aPlainClickPicksOneAlone() {
        var picked = SelectionSet<String>(["a", "c"])
        picked.click("d", .only, in: order)
        #expect(picked.items == ["d"])
        #expect(picked.single == "d")
    }

    @Test func commandClickAddsAndTakesOut() {
        var picked = SelectionSet<String>()
        picked.click("b", .only, in: order)
        picked.click("d", .toggle, in: order)
        #expect(picked.items == ["b", "d"])
        picked.click("b", .toggle, in: order)
        #expect(picked.items == ["d"])
    }

    @Test func shiftClickPicksTheRunFromTheLastClicked() {
        var picked = SelectionSet<String>()
        picked.click("b", .only, in: order)
        picked.click("d", .extend, in: order)
        #expect(picked.items == ["b", "c", "d"])
        // Again from the same anchor, the other way, in place of the last run.
        picked.click("a", .extend, in: order)
        #expect(picked.items == ["a", "b"])
        // With nothing clicked before, it is a plain click.
        var fresh = SelectionSet<String>()
        fresh.click("c", .extend, in: order)
        #expect(fresh.items == ["c"])
    }

    @Test func pressingAPickedThingKeepsTheRestForADrag() {
        var picked = SelectionSet<String>(["a", "b"])
        picked.press("b", .only)
        #expect(picked.items == ["a", "b"])
        picked.press("c", .only)
        #expect(picked.items == ["c"])
        picked.press("d", .extend)
        #expect(picked.items == ["c", "d"])
    }

    @Test func aLassoReplacesOrAdds() {
        var picked = SelectionSet<String>(["a"])
        picked.lasso(["c", "d"], keeping: [])
        #expect(picked.items == ["c", "d"])
        picked.lasso(["e"], keeping: picked.items)
        #expect(picked.items == ["c", "d", "e"])
    }

    @Test func whatIsGoneIsLetGo() {
        var picked = SelectionSet<String>(["a", "b"], anchor: "a")
        picked.keep(only: ["b", "c"])
        #expect(picked.items == ["b"])
        #expect(picked.anchor == nil)
    }
}
